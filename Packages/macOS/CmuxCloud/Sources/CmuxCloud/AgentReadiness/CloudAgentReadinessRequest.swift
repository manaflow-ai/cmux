import CmuxFoundation
import Foundation

/// The agents a readiness check knows. `gh` covers both `gh` and `git` over HTTPS.
public enum CloudAgentReadinessAgent: String, CaseIterable, Codable, Hashable, Sendable {
    case claude
    case codex
    case opencode
    case pi
    case gh

    /// The agent a user typed (`git` is the GitHub row), or nil.
    public init?(argument: String) {
        let raw = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw == "git" {
            self = .gh
            return
        }
        self.init(rawValue: raw)
    }
}

/// One readiness check on a Cloud machine: which agents, whether to make the live
/// auth probe, and whether to stay inside the pre-launch budget.
///
/// The check is one names-only shell script run over `vm.exec`, like Cloud
/// Secrets' provider routing guard: no secret value is in the script, its
/// arguments, or its output. The output is names, fixed words, hosts, and HTTP
/// status codes (``CloudAgentReadinessReport``).
public struct CloudAgentReadinessRequest: Hashable, Sendable {
    /// nil checks every agent.
    public let agent: CloudAgentReadinessAgent?
    /// Make one minimal, no-cost request per key to that key's provider (a models
    /// or rate-limit listing) and report only its HTTP status.
    public let probe: Bool
    /// The pre-launch form: no network at all (no probe, no account check), and
    /// the cached account answer only.
    public let fast: Bool

    public init(agent: CloudAgentReadinessAgent? = nil, probe: Bool = false, fast: Bool = false) {
        self.agent = agent
        self.probe = probe && !fast
        self.fast = fast
    }

    /// How long the machine may take, in milliseconds.
    public var execTimeoutMs: Int {
        if fast { return 4_000 }
        return probe ? 60_000 : 20_000
    }

    /// The `vm.exec` command: `sh -c <script> cmux-agent-readiness <agent|all> <probe> <fast>`.
    public var command: String {
        [
            "sh", "-c", Self.script, "cmux-agent-readiness",
            agent?.rawValue ?? "all", probe ? "1" : "0", fast ? "1" : "0",
        ]
        .map(\.posixShellWord)
        .joined(separator: " ")
    }

    // BEGIN cmux-agent-readiness-script (web/tests/vm-agent-readiness.test.ts runs this script)
    static let script = #"""
# cmux agent readiness. Names and constants only: no secret value is in this
# script, its arguments or its output. For each agent CLI it reports whether it
# is installed, which credential its next launch uses (a key in the machine env,
# its own sign-in, cmux model routing, or none), where that launch sends it, and
# with $2=1 the HTTP status of one minimal no-cost request to that key's
# provider. The probe URLs are the constants below, never a URL read from the
# machine, and a key is probed only when its launch goes to that same provider:
# a key bound for cmux model routing or an endpoint of the user's own is never
# sent anywhere. The key reaches curl on its standard input (a shell builtin
# writes it), never in an argument. $1: an agent or "all"; $3=1: no network.
set -u
want=${1:-all}
probe=${2:-0}
fast=${3:-0}
[ "$fast" = 1 ] && probe=0
etc=${CMUX_ROUTING_ETC:-/etc/cmux}
home=${HOME:-/root}
envf="$home/.config/cmux/env"
placeholder=cmux-vm-edge-placeholder
plane=""
if [ -f "$etc/model-plane.env" ]; then
  plane=$(CMUX_CODEROUTER_URL=""; . "$etc/model-plane.env" >/dev/null 2>&1; printf '%s' "${CMUX_CODEROUTER_URL:-}")
fi
plane=${plane%/}
# The image's sign-in mode resolver, when it parses (older images lack it).
auth=0
if [ -f "$etc/agent-auth.sh" ] && (. "$etc/agent-auth.sh") >/dev/null 2>&1; then
  . "$etc/agent-auth.sh" >/dev/null 2>&1 && auth=1
fi

tok() { printf '%s' "$1" | tr -c 'A-Za-z0-9._:@+-' '_' | cut -c1-64; }
# A URL's host only: no scheme, user info, path, query or fragment.
host_of() {
  h=${1#*://}; h=${h%%/*}; h=${h%%\?*}; h=${h%%#*}; h=${h##*@}
  tok "$h"
}
# A name the env file sets to something other than the public placeholder.
in_env() { grep -E "^export ($1)=" "$envf" 2>/dev/null | grep -qvx -E "export ($1)='$placeholder'"; }
# A non-secret value (an endpoint URL) from the env file, by name.
env_url() { sed -n "s/^export $1='\(.*\)'\$/\1/p" "$envf" 2>/dev/null | tail -n 1; }
first_key() {
  for n in "$@"; do
    if in_env "$n"; then printf '%s' "$n"; return 0; fi
  done
  return 1
}
on_plane() { [ -n "$plane" ] && { [ "${1%/}" = "$plane" ] || [ "${1#"$plane"/}" != "$1" ]; }; }
# ep_kind/ep_host for a launch that sends to $1 (empty: the default, $2).
classify() {
  if [ -z "$1" ]; then ep_kind=provider; ep_host=$2; return 0; fi
  ep_host=$(host_of "$1")
  if on_plane "$1"; then ep_kind=cmux
  elif [ "$ep_host" = "$2" ]; then ep_kind=provider
  else ep_kind=custom
  fi
}
provider_host() {
  case "$1" in
    ANTHROPIC_*) printf api.anthropic.com ;;
    OPENAI_*) printf api.openai.com ;;
    OPENROUTER_*) printf openrouter.ai ;;
    GEMINI_*|GOOGLE_*) printf generativelanguage.googleapis.com ;;
    GH_*|GITHUB_*) printf api.github.com ;;
    XAI_*) printf api.x.ai ;;
    GROQ_*) printf api.groq.com ;;
    MISTRAL_*) printf api.mistral.ai ;;
    DEEPSEEK_*) printf api.deepseek.com ;;
  esac
}
version_of() {
  [ -f "$etc/tool-versions" ] || return 0
  tok "$(awk -v a="$1" '{ for (i = 1; i < NF; i++) if ($i == a) { print $(i + 1); exit } }' "$etc/tool-versions" 2>/dev/null)"
}

# The cached account answer the launchers keep (~/.cache/cmux/agent-access),
# read only: 0 an account, 1 none, 2 unknown, 3 unreachable.
cached_access() {
  case "$1" in claude) f=2 ;; codex) f=3 ;; opencode) f=4 ;; *) return 2 ;; esac
  line=$(head -n 1 "$home/.cache/cmux/agent-access" 2>/dev/null) || line=""
  case "$line" in *[!0-9\ ]*|'') return 2 ;; esac
  at=${line%% *}
  case "$at" in ?????????????*) return 2 ;; esac
  now=$(date +%s 2>/dev/null) || now=0
  if [ "$now" -lt "$at" ] || [ $((now - at)) -ge 300 ]; then return 2; fi
  code=$(printf '%s\n' "$line" | cut -d ' ' -f "$f")
  case "$code" in 0|1|3) return "$code" ;; esac
  return 2
}
team_access() {
  if [ "$fast" = 1 ]; then cached_access "$1"; return $?; fi
  CMUX_CODEROUTER_URL=${CMUX_CODEROUTER_URL:-$plane}
  cmux_agent_team_access "$1"
}
# The launchers' own mode resolution (agent-auth.sh): am=team|own|unknown, ar=why.
resolve_mode() {
  am=unknown; ar=unknown; login=0
  [ "$auth" = 1 ] || return 0
  if cmux_agent_has_own_login "$1"; then login=1; fi
  upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  eval "am=\${CMUX_${upper}_AUTH-}"
  case "$am" in team|own) ar=env; return 0 ;; esac
  am=$(cmux_agent_auth_choice "$1")
  if [ -n "$am" ]; then ar=chosen; return 0; fi
  if [ "$login" = 1 ]; then am=own; ar=login; return 0; fi
  team_access "$1"
  case $? in
    0) am=team; ar=team-account ;;
    1) am=own; ar=no-team-account ;;
    3) am=own; ar=team-unreachable ;;
    *) am=team; ar=team-unknown ;;
  esac
}
# A provider's base_url in codex's config, by provider name.
codex_url() {
  awk -v want="[model_providers.$1]" '
    /^\[/ { block = ($0 == want) }
    block && /^base_url = "/ { sub(/^base_url = "/, ""); sub(/".*$/, ""); print; exit }
  ' "$2" 2>/dev/null
}

# probe <NAME>: the HTTP status of one request to NAME's provider, "unreachable",
# "unsupported", or "skipped" (a value curl's config could not carry verbatim).
probe_key() {
  case "$1" in
    ANTHROPIC_API_KEY) url=https://api.anthropic.com/v1/models; hdr=x-api-key; pre=""; extra="anthropic-version: 2023-06-01" ;;
    ANTHROPIC_AUTH_TOKEN) url=https://api.anthropic.com/v1/models; hdr=Authorization; pre="Bearer "; extra="anthropic-version: 2023-06-01" ;;
    OPENAI_API_KEY) url=https://api.openai.com/v1/models; hdr=Authorization; pre="Bearer "; extra="" ;;
    OPENROUTER_API_KEY) url=https://openrouter.ai/api/v1/key; hdr=Authorization; pre="Bearer "; extra="" ;;
    GEMINI_API_KEY|GOOGLE_GENERATIVE_AI_API_KEY) url=https://generativelanguage.googleapis.com/v1beta/models; hdr=x-goog-api-key; pre=""; extra="" ;;
    GH_TOKEN|GITHUB_TOKEN) url=https://api.github.com/rate_limit; hdr=Authorization; pre="Bearer "; extra="Accept: application/vnd.github+json" ;;
    *) printf unsupported; return 0 ;;
  esac
  command -v curl >/dev/null 2>&1 || { printf unsupported; return 0; }
  eval "pv=\${$1-}"
  case "$pv" in ''|"$placeholder"|*[!A-Za-z0-9._~+/=-]*) pv=""; printf skipped; return 0 ;; esac
  code=$(
    {
      printf 'header = "%s: %s%s"\n' "$hdr" "$pre" "$pv"
      [ -z "$extra" ] || printf 'header = "%s"\n' "$extra"
    } | curl -K - -s -o /dev/null -w '%{http_code}' --proto '=https' --max-redirs 0 \
      --connect-timeout 3 --max-time 6 "$url" 2>/dev/null
  ) || :
  pv=""
  case "$code" in 000|'') printf unreachable ;; [1-5][0-9][0-9]) printf '%s' "$code" ;; *) printf unreachable ;; esac
}
# pr: one probe per key name per run (claude and pi can share a key).
probed=""
probe_cached() {
  for entry in $probed; do
    case "$entry" in "$1="*) pr=${entry#*=}; return 0 ;; esac
  done
  pr=$(probe_key "$1")
  probed="$probed $1=$pr"
}

emit() {
  pr=-
  if [ "$probe" = 1 ] && [ "$src" = key ] && { [ "$ep_kind" = provider ] || [ "$ep_kind" = unrouted ]; }; then
    probe_cached "$key"
  fi
  printf 'agent=%s installed=%s version=%s source=%s key=%s mode=%s reason=%s endpoint=%s host=%s probe=%s helper=%s\n' \
    "$1" "$inst" "$(tok "${ver:--}")" "$src" "$(tok "${key:--}")" "$am" "$ar" "$ep_kind" "$(tok "${ep_host:--}")" "$(tok "$pr")" "$helper"
}
reset() {
  command -v "$1" >/dev/null 2>&1 && inst=1 || inst=0
  ver=$(version_of "$1"); src=none; key=""; ep_kind=none; ep_host=""; helper=-; am=-; ar=-; login=0
}
plane_host() { if [ -n "$plane" ]; then host_of "$plane"; fi; }

check_claude() {
  reset claude
  resolve_mode claude
  if key=$(first_key ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN); then
    src=key
    if in_env ANTHROPIC_BASE_URL; then
      classify "$(env_url ANTHROPIC_BASE_URL)" api.anthropic.com
    elif [ -n "$plane" ] && [ "$am" != own ]; then
      # The model plane's endpoint can outrank the key on this image: Cloud
      # Secrets' routing guard adds the provider's own endpoint beside it.
      ep_kind=unrouted; ep_host=api.anthropic.com
    else
      classify "" api.anthropic.com
    fi
  elif in_env CLAUDE_CODE_OAUTH_TOKEN; then
    src=login; key=CLAUDE_CODE_OAUTH_TOKEN; classify "" api.anthropic.com
  elif [ "$am" = own ] && [ "$login" = 1 ]; then
    src=login; classify "" api.anthropic.com
  elif [ "$am" = team ] || { [ "$am" = unknown ] && [ -n "$plane" ]; }; then
    if [ -n "$plane" ]; then src=routing; ep_kind=cmux; ep_host=$(plane_host); fi
  fi
  emit claude
}

check_codex() {
  reset codex
  resolve_mode codex
  cfg="${CODEX_HOME:-$home/.codex}/config.toml"
  prov=$(sed -n 's/^model_provider = "\(.*\)"$/\1/p' "$cfg" 2>/dev/null | head -n 1)
  if key=$(first_key OPENAI_API_KEY); then
    src=key
    case "$prov" in
      cmux-openai-key) classify "$(codex_url cmux-openai-key "$cfg")" api.openai.com ;;
      cmux)
        if [ "$am" = own ] || grep -qs cmux_codex_user_key_provider "$etc/agent-auth.sh"; then
          classify "$(env_url OPENAI_BASE_URL)" api.openai.com
        else
          # The model router's provider authenticates with OPENAI_API_KEY.
          ep_kind=cmux; ep_host=$(host_of "$(codex_url cmux "$cfg")")
        fi
        ;;
      '') classify "$(env_url OPENAI_BASE_URL)" api.openai.com ;;
      *) ep_kind=custom; ep_host=$(host_of "$(codex_url "$prov" "$cfg")") ;;
    esac
  elif [ "$am" = own ]; then
    if [ "$login" = 1 ]; then src=login; classify "" api.openai.com; fi
  elif [ -n "$prov" ] && [ "$prov" != cmux ]; then
    src=config; ep_kind=custom; ep_host=$(host_of "$(codex_url "$prov" "$cfg")")
  elif [ -n "$plane" ] && { [ "$am" = team ] || [ "$am" = unknown ]; }; then
    src=routing; ep_kind=cmux; ep_host=$(plane_host)
  fi
  emit codex
}

provider_keys="ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY XAI_API_KEY GROQ_API_KEY MISTRAL_API_KEY DEEPSEEK_API_KEY"

check_opencode() {
  reset opencode
  resolve_mode opencode
  # shellcheck disable=SC2086
  userkey=$(first_key $provider_keys) || userkey=""
  if [ "$am" = team ] && [ -n "$plane" ]; then
    src=routing; key=$userkey; ep_kind=cmux; ep_host=$(plane_host)
  elif [ "$login" = 1 ]; then
    src=login; key=$userkey; ep_kind=provider; ep_host=-
  elif [ -n "$userkey" ]; then
    src=key; key=$userkey
    if [ "$key" = OPENAI_API_KEY ] && in_env OPENAI_BASE_URL; then
      classify "$(env_url OPENAI_BASE_URL)" api.openai.com
    else
      classify "" "$(provider_host "$key")"
    fi
  elif [ "$am" = unknown ] && [ -n "$plane" ]; then
    src=routing; ep_kind=cmux; ep_host=$(plane_host)
  fi
  emit opencode
}

check_pi() {
  reset pi
  am=-; ar=-
  # shellcheck disable=SC2086
  if key=$(first_key $provider_keys); then
    src=key; classify "" "$(provider_host "$key")"
  elif [ -s "$home/.pi/agent/auth.json" ] && grep -q '"' "$home/.pi/agent/auth.json" 2>/dev/null; then
    src=login; ep_kind=provider; ep_host=-
  elif [ -n "$plane" ] && grep -qsF "\"baseUrl\": \"$plane" "$home/.pi/agent/models.json"; then
    src=routing; ep_kind=cmux; ep_host=$(plane_host)
  fi
  emit pi
}

check_gh() {
  reset gh
  [ "$inst" = 1 ] || { command -v git >/dev/null 2>&1 && inst=1; }
  if command -v git >/dev/null 2>&1; then
    if git config --global --get credential.https://github.com.helper >/dev/null 2>&1; then helper=1; else helper=0; fi
  fi
  gh_hosts="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$home/.config}/gh}/hosts.yml"
  if key=$(first_key GH_TOKEN GITHUB_TOKEN); then
    src=key
    case "${GH_HOST:-github.com}" in
      github.com|api.github.com) ep_kind=provider; ep_host=api.github.com ;;
      *) ep_kind=custom; ep_host=$(tok "$GH_HOST") ;;
    esac
  elif grep -qsE '^[[:space:]]+(oauth_token|user):' "$gh_hosts"; then
    src=login; ep_kind=provider; ep_host=api.github.com
  fi
  emit gh
}

printf 'cmux-agent-readiness v1 plane=%s auth=%s\n' "$([ -n "$plane" ] && echo 1 || echo 0)" "$auth"
for agent in claude codex opencode pi gh; do
  if [ "$want" = all ] || [ "$want" = "$agent" ]; then "check_$agent"; fi
done
printf 'cmux-agent-readiness end\n'
exit 0
"""#
    // END cmux-agent-readiness-script
}
