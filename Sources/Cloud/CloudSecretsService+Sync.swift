import CmuxCloud
import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

extension CloudSecretsService.Transport {
    /// Values over the machine's cmux-tui link (`CloudEnvDelivery`), names over `vm.exec`,
    /// the same two channels `vm.env_set` and `cmux vm env rm` use.
    static let live = CloudSecretsService.Transport(
        deliver: { machineID, entries in
            let provider = try await TerminalController.cloudTuiProvider(machineID: machineID, catalog: await SurfaceCatalog.shared)
            _ = try await provider.deliverEnvironment(entries)
        },
        exec: { machineID, command in
            // A machine of another team is reachable only under its owning team.
            let teamID = await CmuxTuiSurfaceProviderRegistry.shared.ownerTeamID(forMachineID: machineID)
            return try await VMClient.shared.exec(
                id: machineID,
                command: command,
                timeoutMs: CloudSecretsService.execTimeoutMs,
                teamID: teamID
            )
        }
    )
}

extension CloudSecretsService {
    nonisolated static let execTimeoutMs = 30_000

    /// Names whose presence makes sync configure git's GitHub credential helper.
    nonisolated static let gitTokenNames: Set<String> = ["GH_TOKEN", "GITHUB_TOKEN"]

    /// A distinctive helper that reads the token from the environment at use time,
    /// so no value is ever in argv, a config file, or the exec channel. The function
    /// name is part of the marker: cleanup can remove only the helper cmux added.
    nonisolated static let gitCredentialHelperValue = #"!cmux_cloud_github_token_helper_v1() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=${GH_TOKEN:-$GITHUB_TOKEN}"; }; cmux_cloud_github_token_helper_v1"#

    /// The helper written by the first version of Cloud Secrets. Remove it during
    /// cleanup too, so machines upgraded in place do not retain an empty-password
    /// helper after their token is removed.
    nonisolated static let legacyGitCredentialHelperValue = #"!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=${GH_TOKEN:-$GITHUB_TOKEN}"; }; f"#

    /// Adds the cmux helper only when it is not already present. `--add` preserves
    /// any helper the user configured; Git tries helpers in config order.
    nonisolated static var gitCredentialHelperCommand: String {
        let key = "credential.https://github.com.helper"
        let helper = gitCredentialHelperValue.posixShellWord
        return "if git config --global --get-all \(key.posixShellWord) 2>/dev/null | grep -F -x -- \(helper) >/dev/null 2>&1; then exit 0; else git config --global --add \(key.posixShellWord) \(helper); fi"
    }

    /// Removes only helpers whose exact value is one of the cmux-owned versions.
    /// A user's unrelated GitHub helper remains intact.
    nonisolated static var gitCredentialHelperCleanupCommand: String {
        let key = "credential.https://github.com.helper".posixShellWord
        let values = [gitCredentialHelperValue, legacyGitCredentialHelperValue]
            .map { "git config --global --unset-all --fixed-value \(key) \($0.posixShellWord) >/dev/null 2>&1 || true" }
        return values.joined(separator: "; ")
    }

    /// The machine shim's names-only removal: `cmux env rm NAME…`.
    nonisolated static func envRemoveCommand(names: [String]) -> String {
        (["cmux", "env", "rm"] + names).map(\.posixShellWord).joined(separator: " ")
    }

    /// The machine shim's names-only listing.
    nonisolated static let envListCommand = "cmux env ls --json"

    /// One sync attempt. Only ever called through ``sync(machineID:projectKey:)``'s
    /// per-machine chain.
    ///
    /// Provider routing (``CloudSecretsProviderRouting``) brackets the delivery: the
    /// guard protects every user provider key before any key lands, so a key never
    /// meets the model router's endpoint, and releases a cmux-added endpoint only
    /// after its key was removed. A guard that fails before delivery stops the sync:
    /// a key is never delivered to a machine that would send it to cmux.
    func performSync(machineID: String) async -> CloudSecretSyncResult {
        let plan: CloudSecretPlan
        do {
            plan = try await vault.plan(machineID: machineID)
        } catch {
            return await failure(machineID: machineID, error: error, values: [])
        }
        let values = plan.toSend.map(\.value)
        let routing = CloudSecretsProviderRouting(effectiveNames: plan.effective.keys)
        let routesMachine = needsProviderRouting(routing, plan: plan)
        if plan.isNoop {
            // A machine the ledger has never seen gets an entry, so later changes to
            // the `all` scope reach it through ``syncAllStale()``.
            var routingError: String?
            do {
                if routesMachine {
                    let result = try await applyProviderRouting(routing, machineID: machineID)
                    if result.isRouted {
                        recordProviderRouting(routing, machineID: machineID)
                    } else {
                        routingError = CloudSecretsProviderRouting.heldBackMessage(
                            result.heldBack(names: plan.effective.keys), retries: true
                        )
                    }
                }
                if try await vault.delivery(for: machineID) == nil {
                    try await vault.recordDelivered(machineID: machineID, plan: plan, at: Date())
                }
                if let routingError {
                    try await vault.recordFailure(machineID: machineID, message: routingError)
                }
                await reload()
                postDidChange()
            } catch {
                return await failure(machineID: machineID, error: error, values: values)
            }
            var configuredGit = false
            if !Self.gitTokenNames.isDisjoint(with: plan.effective.keys) {
                if let result = try? await transport.exec(machineID, Self.gitCredentialHelperCommand),
                   result.exitCode == 0 {
                    configuredGit = true
                }
            } else if plan.toRemove.contains(where: Self.gitTokenNames.contains) {
                _ = try? await transport.exec(machineID, Self.gitCredentialHelperCleanupCommand)
            }
            return CloudSecretSyncResult(
                machineID: machineID, sent: [], removed: [], noop: true,
                configuredGitCredentials: configuredGit, error: routingError
            )
        }
        var configuredGit = false
        // Keys of a provider the guard could not route wait for a later sync;
        // everything else is delivered now.
        var heldBack: [String: CloudSecretsProviderRouting.HoldReason] = [:]
        var routed = true
        var toSend = plan.toSend
        do {
            if routesMachine, routing.hasUserProviderKey {
                let result = try await applyProviderRouting(routing.protectingOnly, machineID: machineID)
                heldBack = result.heldBack(names: plan.sendNames)
                routed = result.isRouted
                toSend = plan.toSend.filter { heldBack[$0.key] == nil }
            }
            if !toSend.isEmpty {
                try await transport.deliver(machineID, toSend)
            }
            if !plan.toRemove.isEmpty {
                let result = try await transport.exec(machineID, Self.envRemoveCommand(names: plan.toRemove))
                try Self.requireShimSuccess(result, machineID: machineID)
            }
            if routesMachine,
               routing.hasUserProviderKey || routing.releasesEndpoint || routing.usesUserEndpoint {
                // Run once after delivery as well. A fresh machine has no user key
                // for the protecting pass to inspect, so this is where Claude's
                // approval suffix and other per-key config can be derived locally.
                // When the last provider key is removed, this pass also releases
                // the endpoint cmux previously added beside it. The guard still
                // receives names and constants only.
                let result = try await applyProviderRouting(routing, machineID: machineID)
                routed = routed && result.isRouted
                if routed, heldBack.isEmpty {
                    recordProviderRouting(routing, machineID: machineID)
                }
            }
            if !Self.gitTokenNames.isDisjoint(with: plan.effective.keys) {
                // Best effort: the token itself is delivered; only `git push` over
                // HTTPS depends on the helper, and `gh auth setup-git` remains a fallback.
                // Run this even when the vault plan is otherwise current, because a
                // prior helper setup may have failed after the token was delivered.
                if let result = try? await transport.exec(machineID, Self.gitCredentialHelperCommand),
                   result.exitCode == 0 {
                    configuredGit = true
                }
            } else if plan.toRemove.contains(where: Self.gitTokenNames.contains) {
                // Do not leave a cmux helper that returns an empty password: it can
                // prevent a user's own helper from being tried after token removal.
                _ = try? await transport.exec(machineID, Self.gitCredentialHelperCleanupCommand)
            }
            // The ledger records what landed: a held-back key stays missing, so the
            // next sync sends it.
            let delivered = heldBack.isEmpty ? plan : CloudSecretPlan(
                machineID: plan.machineID,
                toSend: toSend,
                toRemove: plan.toRemove,
                effective: plan.effective,
                fingerprints: plan.fingerprints
            )
            try await vault.recordDelivered(machineID: machineID, plan: delivered, at: Date())
        } catch {
            return await failure(machineID: machineID, error: error, values: values)
        }
        var error: String?
        if !heldBack.isEmpty {
            let message = CloudSecretsProviderRouting.heldBackMessage(heldBack, retries: true)
            try? await vault.recordFailure(machineID: machineID, message: message)
            error = message
        }
        await reload()
        postDidChange()
        return CloudSecretSyncResult(
            machineID: machineID,
            sent: toSend.map(\.key),
            removed: plan.toRemove,
            noop: false,
            configuredGitCredentials: configuredGit,
            error: error
        )
    }

    /// Records the failure in the chain before returning, so it can never land after
    /// a later sync of the same machine succeeded.
    private func failure(machineID: String, error: Error, values: [String]) async -> CloudSecretSyncResult {
        let message = Self.redactedMessage(for: error, values: values)
#if DEBUG
        cmuxDebugLog("cloudSecrets.sync.failed machine=\(machineID) error=\(type(of: error))")
#endif
        try? await vault.recordFailure(machineID: machineID, message: message)
        await reload()
        postDidChange()
        return CloudSecretSyncResult(
            machineID: machineID, sent: [], removed: [], noop: false,
            configuredGitCredentials: false, error: message
        )
    }

    // MARK: - Shim results

    struct ShimFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A shim too old for `cmux env`, or a non-zero exit, becomes a redacted failure.
    nonisolated static func requireShimSuccess(_ result: VMExecResult, machineID: String) throws {
        let text = result.stdout + "\n" + result.stderr
        if text.contains("unknown resource scope") || text.contains("unknown vm subcommand") {
            throw CloudEnvDelivery.DeliveryError.outdatedShim(machineID)
        }
        guard result.exitCode == 0 else {
            throw ShimFailure(message: String(
                format: String(localized: "cloudSecrets.sync.error.shimExit", defaultValue: "The machine could not update its environment (exit %ld)."),
                result.exitCode
            ))
        }
    }

    /// The names in `cmux env ls --json` output (`{path, keys: [...]}`).
    nonisolated static func parseEnvListNames(_ result: VMExecResult, machineID: String) throws -> Set<String> {
        try requireShimSuccess(result, machineID: machineID)
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let data = String(trimmed[start...]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let keys = object["keys"] as? [String] else {
            throw ShimFailure(message: String(
                localized: "cloudSecrets.sync.error.unreadableEnvList",
                defaultValue: "The machine's environment list could not be read."
            ))
        }
        return Set(keys)
    }

    // MARK: - Redaction

    /// Human text for a failure that can never carry a value: known errors map to fixed
    /// copy, anything that could echo a screen or request becomes a generic line, and any
    /// value of the plan that still appears is masked as a last line of defense.
    nonisolated static func redactedMessage(for error: Error, values: [String]) -> String {
        let message: String
        if let validation = error as? CloudSecretValidationError {
            message = validation.errorDescription ?? genericSyncFailure
        } else if let vaultError = error as? CloudSecretVaultError {
            message = vaultError.errorDescription ?? genericSyncFailure
        } else if let storageError = error as? CloudSecretVaultStorageError {
            message = storageError.errorDescription ?? genericSyncFailure
        } else if let delivery = error as? CloudEnvDelivery.DeliveryError {
            switch delivery {
            case .outdatedShim, .invalidKey, .reservedKey, .multilineValue, .tooLarge, .emptyPayload, .workspaceCleanupFailed:
                message = delivery.errorDescription ?? genericSyncFailure
            case .receiverFailed, .receiverNotReady, .noResult:
                message = String(
                    localized: "cloudSecrets.sync.error.receiver",
                    defaultValue: "The machine did not accept the secrets. Reconnect it and try again."
                )
            }
        } else if let catalogError = error as? SurfaceCatalogError, case .noProvider = catalogError {
            message = String(
                localized: "cloudSecrets.sync.error.notConnected",
                defaultValue: "The machine is not connected. Start or wake it, then sync again."
            )
        } else if let shim = error as? ShimFailure {
            message = shim.message
        } else if error is CancellationError {
            message = String(localized: "cloudSecrets.sync.error.cancelled", defaultValue: "The sync was cancelled.")
        } else {
            message = genericSyncFailure
        }
        return mask(message, values: values)
    }

    nonisolated static var genericSyncFailure: String {
        String(
            localized: "cloudSecrets.sync.error.generic",
            defaultValue: "The secrets could not be sent to the machine. Make sure it is running and try again."
        )
    }

    /// Replaces any occurrence of a value (4+ characters) with a fixed mask.
    nonisolated static func mask(_ text: String, values: [String]) -> String {
        var masked = text
        for value in values where value.count >= 4 {
            masked = masked.replacingOccurrences(of: value, with: "••••")
        }
        return masked
    }
}

// MARK: - Provider routing

/// Where a machine's provider keys go. Every Cloud machine has a model plane: its
/// shells point `OPENAI_BASE_URL` (and, on older images, `ANTHROPIC_BASE_URL`) at
/// cmux's model router, with a public placeholder key the machine's edge replaces.
/// A key the user put in Cloud Secrets must never ride that endpoint, so beside a
/// user's provider key with no endpoint of their own, sync also gives the machine
/// the provider's own endpoint (a derived, non-secret companion) and runs
/// ``guardScript`` once over `vm.exec`: names and constants only, no value.
///
/// Precedence on the machine: a user's provider key always goes directly to that
/// provider; the model plane applies only to a provider the user gave no key for.
struct CloudSecretsProviderRouting: Equatable, Sendable {
    /// One provider's routing on a machine.
    enum Mode: String, Equatable, Sendable {
        /// The user has a key and no endpoint of their own: cmux adds the
        /// provider's own endpoint beside it.
        case direct
        /// The user has a key and their own endpoint in Cloud Secrets.
        case user
        /// No key of the user's: the model plane applies, and an endpoint cmux
        /// added earlier is removed.
        case plane
        /// Leave the endpoint as it is: used before a sync's removals ran, so a
        /// key on its way out never sits beside the model router's endpoint.
        case keep
    }

    static let openAIKeyNames: Set<String> = ["OPENAI_API_KEY"]
    static let openAIEndpointName = "OPENAI_BASE_URL"
    static let openAIEndpoint = "https://api.openai.com/v1"
    static let anthropicKeyNames: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
    static let anthropicEndpointName = "ANTHROPIC_BASE_URL"
    static let anthropicEndpoint = "https://api.anthropic.com"

    /// What a machine that never ran the guard is in: nothing to release.
    static let unrouted = CloudSecretsProviderRouting(openAI: .plane, anthropic: .plane)

    let openAI: Mode
    let anthropic: Mode

    init(openAI: Mode, anthropic: Mode) {
        self.openAI = openAI
        self.anthropic = anthropic
    }

    /// The routing a machine needs for the names its effective set holds.
    init<Names: Sequence>(effectiveNames: Names) where Names.Element == String {
        let names = Set(effectiveNames)
        func mode(keys: Set<String>, endpoint: String) -> Mode {
            guard !keys.isDisjoint(with: names) else { return .plane }
            return names.contains(endpoint) ? .user : .direct
        }
        self.init(
            openAI: mode(keys: Self.openAIKeyNames, endpoint: Self.openAIEndpointName),
            anthropic: mode(keys: Self.anthropicKeyNames, endpoint: Self.anthropicEndpointName)
        )
    }

    /// True when any provider key of the user's is in the set.
    var hasUserProviderKey: Bool { openAI == .direct || openAI == .user || anthropic == .direct || anthropic == .user }

    /// True when a provider uses the user's own endpoint from Cloud Secrets.
    var usesUserEndpoint: Bool { openAI == .user || anthropic == .user }

    /// True when a provider falls back to the model plane, so an endpoint cmux
    /// added for it earlier is released.
    var releasesEndpoint: Bool { openAI == .plane || anthropic == .plane }

    /// This routing without its releases: what runs before keys are delivered
    /// and removed.
    var protectingOnly: CloudSecretsProviderRouting {
        CloudSecretsProviderRouting(
            openAI: openAI == .plane ? .keep : openAI,
            anthropic: anthropic == .plane ? .keep : anthropic
        )
    }

    /// The derived, non-secret endpoints the guard gives the machine beside the
    /// user's keys (name, value). Constants: never a vault value.
    var companionEndpoints: [(name: String, value: String)] {
        var endpoints: [(name: String, value: String)] = []
        if openAI == .direct { endpoints.append((Self.openAIEndpointName, Self.openAIEndpoint)) }
        if anthropic == .direct { endpoints.append((Self.anthropicEndpointName, Self.anthropicEndpoint)) }
        return endpoints
    }

    /// Stored per machine once the guard ran for this routing; a change reruns it.
    var marker: String { "v1;openai=\(openAI.rawValue);anthropic=\(anthropic.rawValue)" }

    /// The names-only `vm.exec` command that applies this routing.
    var command: String {
        ["sh", "-c", Self.guardScript, "cmux-provider-routing", openAI.rawValue, anthropic.rawValue]
            .map(\.posixShellWord)
            .joined(separator: " ")
    }

    // BEGIN cmux-provider-routing-guard (web/tests/vm-provider-routing-guard.test.ts runs this script)
    static let guardScript = #"""
# cmux Cloud Secrets provider routing. Names and constants only: no secret
# value is in this script, its arguments or its output. A user's own provider
# key always reaches that provider directly, never cmux's model router; the
# model plane applies only to a provider the user gave no key for. Runs on
# every image generation, including machines whose baked guest files predate
# this precedence. $1: OpenAI mode, $2: Anthropic mode: direct (a user key, no
# endpoint of theirs), user (a user key and their endpoint), plane (no user
# key), keep (leave that provider's endpoint as it is).
#
# Its only output is one line, CMUX-ROUTING-RESULT openai=<r> anthropic=<r>,
# where <r> is ok or why that provider's key must not land yet: env (its
# endpoint could not be written), plane-copy (the model-plane copy could not
# be neutralized), codex, opencode. The Mac holds back only those keys and
# delivers everything else. Nothing here needs the network: this exec channel
# may not resolve the model router's alias at all.
set -u
openai=${1:-keep}
anthropic=${2:-keep}
user_key() { [ "$1" = direct ] || [ "$1" = user ]; }
etc=${CMUX_ROUTING_ETC:-/etc/cmux}
home=${HOME:-/root}
envf="$home/.config/cmux/env"
placeholder=cmux-vm-edge-placeholder
fail_openai=""
fail_anthropic=""
# fail <openai|anthropic|both> <cause>: the first cause per provider wins.
fail() {
  case "$1" in openai|both) [ -n "$fail_openai" ] || fail_openai=$2 ;; esac
  case "$1" in anthropic|both) [ -n "$fail_anthropic" ] || fail_anthropic=$2 ;; esac
}
plane=""
if [ -f "$etc/model-plane.env" ]; then
  plane=$(CMUX_CODEROUTER_URL=""; . "$etc/model-plane.env" >/dev/null 2>&1; printf '%s' "${CMUX_CODEROUTER_URL:-}")
fi
plane=${plane%/}

# 1. The persisted model plane never holds a copy of a user's value. Older
# images copy whatever key a shell carries into this home's copy; the baked
# file holds the same plane, so point the copy at /dev/null and every reader
# falls back to the baked file.
mp="$home/.config/cmux/model-plane.env"
if [ -f "$etc/model-plane.env" ]; then
  if [ ! -L "$mp" ] || [ "$(readlink "$mp")" != /dev/null ]; then
    { mkdir -p "$home/.config/cmux" && ln -sfn /dev/null "$mp"; } || fail both plane-copy
  fi
elif [ -f "$mp" ]; then
  {
    grep -v -E "^export (OPENAI|ANTHROPIC)_API_KEY=" "$mp" || :
    grep -x -E "export (OPENAI|ANTHROPIC)_API_KEY='$placeholder'" "$mp" || :
  } > "$mp.cmux-tmp" && chmod 600 "$mp.cmux-tmp" && mv -f "$mp.cmux-tmp" "$mp" || fail both plane-copy
fi

# A provider key can reach the env file outside Cloud Secrets (`cmux vm env
# set`, or `cmux env set` on the machine). Never release such a provider to the
# model plane: that would pair the user's key with cmux's router. Names only;
# no value is read. Vault removals run before this script, so a key revoked
# through Cloud Secrets is already gone and its provider is released as asked.
has_key() {
  grep -E "^export ($1)=" "$envf" 2>/dev/null | grep -qvx -E "export ($1)='$placeholder'"
}
if [ "$openai" = plane ] && has_key OPENAI_API_KEY; then openai=direct; fi
if [ "$anthropic" = plane ] && has_key 'ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN'; then anthropic=direct; fi

# 2. Beside a user's key with no endpoint of their own, the provider's own
# endpoint; a cmux-added endpoint goes when the key does.
on_plane() { [ -n "$plane" ] && { [ "${1%/}" = "$plane" ] || [ "${1#"$plane"/}" != "$1" ]; }; }
route() {
  current=$(sed -n "s/^export $2='\(.*\)'\$/\1/p" "$envf" 2>/dev/null | tail -n 1)
  case "$1" in
    direct)
      if [ -z "$current" ] || on_plane "$current"; then
        cmux env set "$2=$3" >/dev/null 2>&1 || fail "$4" env
      fi
      ;;
    plane)
      # A failed release leaves OpenAI's own endpoint without a key: no key is at risk.
      if [ "$current" = "$3" ]; then cmux env rm "$2" >/dev/null 2>&1 || :; fi
      ;;
  esac
}
route "$openai" OPENAI_BASE_URL https://api.openai.com/v1 openai
route "$anthropic" ANTHROPIC_BASE_URL https://api.anthropic.com anthropic

# Claude Code asks once whether a custom API key should be used. The answer is
# keyed by the last 20 characters of the key, so refresh it after every
# delivery, including rotations. The guest derives the suffix from its own
# env file; neither the key nor its suffix is an argument, output, or socket
# response. Keep this best-effort: an approval file is a usability aid, not a
# routing decision, and a failure must never make a delivered key unavailable.
approve_claude_key() {
  [ -f "$envf" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$envf" "$home/.claude.json" <<'CMUX_CLAUDE_APPROVAL' >/dev/null 2>&1 || :
import json
import os
import tempfile
import sys

env_path, config_path = sys.argv[1:]
names = {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"}
placeholder = "cmux-vm-edge-placeholder"

def value_from_line(line):
    if not line.startswith("export ") or "=" not in line:
        return None
    name, raw = line[7:].split("=", 1)
    if name not in names:
        return None
    raw = raw.rstrip("\n")
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        raw = raw[1:-1].replace("'\\''", "'")
    elif len(raw) >= 2 and raw[0] == raw[-1] == '"':
        raw = bytes(raw[1:-1], "utf-8").decode("unicode_escape")
    return raw

keys = []
with open(env_path, encoding="utf-8") as stream:
    for line in stream:
        candidate = value_from_line(line)
        if candidate and candidate != placeholder:
            keys.append(candidate)
if not keys:
    raise SystemExit(0)

try:
    with open(config_path, encoding="utf-8") as stream:
        config = json.load(stream)
except FileNotFoundError:
    config = {}
except (OSError, ValueError):
    # An unreadable or malformed existing config is still valuable user state.
    # Leave it untouched rather than replacing it with an approval-only file.
    raise SystemExit(0)
if not isinstance(config, dict):
    # A valid non-object is not a usable Claude config, but it is still user
    # state; preserve it rather than replacing it with an approval-only file.
    raise SystemExit(0)
responses = config.get("customApiKeyResponses")
if not isinstance(responses, dict):
    responses = {}
approved = responses.get("approved")
if not isinstance(approved, list):
    approved = []
for key in keys:
    suffix = key[-20:]
    if suffix not in approved:
        approved.append(suffix)
responses["approved"] = approved
if not isinstance(responses.get("rejected"), list):
    responses["rejected"] = []
config["customApiKeyResponses"] = responses

directory = os.path.dirname(config_path)
os.makedirs(directory, mode=0o700, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".cmux-claude-", dir=directory, text=True)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(config, stream, separators=(",", ":"))
        stream.write("\n")
    os.replace(temporary, config_path)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
CMUX_CLAUDE_APPROVAL
}
approve_claude_key

# The image's agent-config, run in a shell that carries only the baked plane
# (as the machine's first login shell does), then $1, whose status it returns.
# Its writes to the model-plane copy land in /dev/null (step 1).
plane_shell() {
  [ -f "$etc/agent-config.sh" ] && [ -f "$etc/model-plane.env" ] || return 0
  bash -c 'unset OPENAI_BASE_URL OPENAI_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; . "$1/model-plane.env"; . "$1/agent-config.sh"; '"$1" \
    cmux-routing "$etc" </dev/null >/dev/null 2>&1
}

# 3. codex: a cmux-generated config names the model router as its provider
# and authenticates it with OPENAI_API_KEY. Launchers older than the
# per-launch precedence get the user's key provider in the file instead,
# pointed at the user's own OPENAI_BASE_URL when they have one (read here, on
# the machine, by name: it never leaves it), else OpenAI's own endpoint; never
# one on the model router, and only a plain URL TOML can hold verbatim.
# A brand-new machine whose first sync runs before its first shell has no
# config yet; the first shell would write the model router's provider, so
# write it now and switch it below.
codex_cfg="${CODEX_HOME:-$home/.codex}/config.toml"
if user_key "$openai" && ! grep -qs '^model_provider' "$codex_cfg"; then plane_shell : || :; fi
if [ -f "$codex_cfg" ] && ! grep -qs cmux_codex_user_key_provider "$etc/agent-auth.sh"; then
  if user_key "$openai"; then
    codex_url=https://api.openai.com/v1
    endpoint=$(sed -n "s/^export OPENAI_BASE_URL='\(.*\)'\$/\1/p" "$envf" 2>/dev/null | tail -n 1)
    case "$endpoint" in
      *[!A-Za-z0-9._~:/?#@%+=,-]*) ;;
      http://?*|https://?*) on_plane "$endpoint" || codex_url=$endpoint ;;
    esac
    if grep -qx 'model_provider = "cmux"' "$codex_cfg"; then
      {
        sed 's/^model_provider = "cmux"$/model_provider = "cmux-openai-key"/' "$codex_cfg"
        if ! grep -qx '\[model_providers\.cmux-openai-key\]' "$codex_cfg"; then
          printf '\n# Cloud Secrets: your own OPENAI_API_KEY goes to OpenAI directly.\n[model_providers.cmux-openai-key]\nname = "OpenAI"\nbase_url = "https://api.openai.com/v1"\nenv_key = "OPENAI_API_KEY"\nwire_api = "responses"\n'
        fi
      } > "$codex_cfg.cmux-tmp" && mv -f "$codex_cfg.cmux-tmp" "$codex_cfg" || fail openai codex
    fi
    if grep -qx 'model_provider = "cmux-openai-key"' "$codex_cfg"; then
      awk -v url="$codex_url" '
        /^\[/ { block = ($0 == "[model_providers.cmux-openai-key]") }
        block && /^base_url = / { print "base_url = \"" url "\""; next }
        { print }
      ' "$codex_cfg" > "$codex_cfg.cmux-tmp" || fail openai codex
      if cmp -s "$codex_cfg" "$codex_cfg.cmux-tmp"; then rm -f "$codex_cfg.cmux-tmp"; else mv -f "$codex_cfg.cmux-tmp" "$codex_cfg" || fail openai codex; fi
    fi
  elif [ "$openai" = plane ] && grep -qx 'model_provider = "cmux-openai-key"' "$codex_cfg"; then
    sed 's/^model_provider = "cmux-openai-key"$/model_provider = "cmux"/' "$codex_cfg" > "$codex_cfg.cmux-tmp" \
      && mv -f "$codex_cfg.cmux-tmp" "$codex_cfg" || :
  fi
fi

# 4. OpenCode: the image writes the model router's providers with
# {env:OPENAI_API_KEY} as their key, which is the user's key once they have
# one, and a team-mode launch with no provider file fetches them with
# OPENAI_API_KEY as the credential; a launch that finds the file never
# fetches. Fetch them now in a plane-only shell (the placeholder). When that
# cannot work from here (the alias may not resolve from this exec channel, or
# the router is down), put a cmux stub ({}) in the file's place instead: the
# launch then has its file, adds no team providers, and never sends the
# user's key; the next sync that reaches the router replaces the stub. A file
# that is not cmux's stub is never touched.
if user_key "$openai" && [ -n "$plane" ] && grep -qs 'os.environ\["OPENAI_API_KEY"\]' "$etc/agent-config.sh"; then
  if grep -qs 'opencode-team.json' "$etc/agent-config.sh"; then
    oc_file="$home/.config/cmux/opencode-team.json"
  else
    oc_file="${XDG_CONFIG_HOME:-$home/.config}/opencode/opencode.json"
  fi
  oc_stub="$home/.config/cmux/opencode-providers.cmux-stub"
  is_stub() { [ -f "$oc_stub" ] && [ -f "$oc_file" ] && [ "$(cat "$oc_file" 2>/dev/null)" = "{}" ]; }
  if is_stub; then rm -f "$oc_file"; fi
  if [ ! -e "$oc_file" ]; then plane_shell cmux_ensure_opencode_config || :; fi
  if [ -e "$oc_file" ]; then
    is_stub || rm -f "$oc_stub"
  else
    { mkdir -p "${oc_file%/*}" "$home/.config/cmux" && printf '{}\n' > "$oc_file" && : > "$oc_stub"; } || fail openai opencode
  fi
fi
if command -v python3 >/dev/null 2>&1; then
  python3 - "$plane" "$home/.config/cmux/opencode-team.json" "${XDG_CONFIG_HOME:-$home/.config}/opencode/opencode.json" <<'CMUX_OPENCODE_ROUTING' || fail openai opencode
import json, os, sys, tempfile
plane, files = sys.argv[1], sys.argv[2:]
reference = "{env:OPENAI_API_KEY}"
def fix(value):
    if isinstance(value, dict):
        return {k: fix(v) for k, v in value.items()}
    if isinstance(value, list):
        return [fix(v) for v in value]
    if isinstance(value, str):
        return value.replace(reference, "cmux-vm-edge-placeholder")
    return value
for name in files:
    try:
        with open(name) as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        continue
    providers = document.get("provider") if isinstance(document, dict) else None
    if not isinstance(providers, dict):
        continue
    changed = False
    for key, provider in list(providers.items()):
        options = provider.get("options") if isinstance(provider, dict) else None
        base = options.get("baseURL") if isinstance(options, dict) else None
        if not plane or not isinstance(base, str) or not (base == plane or base.startswith(plane + "/")):
            continue
        fixed = fix(provider)
        if fixed != provider:
            providers[key] = fixed
            changed = True
    if not changed:
        continue
    mode = os.stat(name).st_mode & 0o777
    fd, temporary = tempfile.mkstemp(prefix=".cmux-routing-", dir=os.path.dirname(name))
    with os.fdopen(fd, "w") as output:
        json.dump(document, output)
        output.write("\n")
    os.chmod(temporary, mode)
    os.replace(temporary, name)
CMUX_OPENCODE_ROUTING
fi
printf 'CMUX-ROUTING-RESULT openai=%s anthropic=%s\n' "${fail_openai:-ok}" "${fail_anthropic:-ok}"
exit 0
"""#
    // END cmux-provider-routing-guard
}

extension CloudSecretsService {
    /// The `defaults` key holding the routing marker last applied to `machineID`.
    nonisolated static func providerRoutingDefaultsKey(machineID: String) -> String {
        "cloudSecrets.providerRouting.\(machineID)"
    }

    /// The routing last applied to `machineID`, as its marker.
    func appliedProviderRoutingMarker(machineID: String) -> String {
        defaults.string(forKey: Self.providerRoutingDefaultsKey(machineID: machineID))
            ?? CloudSecretsProviderRouting.unrouted.marker
    }

    /// Ignored for a machine forgotten while its sync was in flight.
    func recordProviderRouting(_ routing: CloudSecretsProviderRouting, machineID: String) {
        guard !forgottenMachineIDs.contains(machineID) else { return }
        defaults.set(routing.marker, forKey: Self.providerRoutingDefaultsKey(machineID: machineID))
    }

    func forgetProviderRouting(machineID: String) {
        defaults.removeObject(forKey: Self.providerRoutingDefaultsKey(machineID: machineID))
    }

    /// True when `plan`'s machine needs the routing guard: its routing changed, or
    /// keys are about to be (re)delivered or removed beside a user's provider key.
    func needsProviderRouting(_ routing: CloudSecretsProviderRouting, plan: CloudSecretPlan) -> Bool {
        if appliedProviderRoutingMarker(machineID: plan.machineID) != routing.marker { return true }
        return routing.hasUserProviderKey && !plan.isNoop
    }

    /// True when `machineID` has secrets to deliver or a routing to apply.
    func machineNeedsSync(_ machineID: String) async throws -> Bool {
        let plan = try await vault.plan(machineID: machineID)
        if !plan.isNoop { return true }
        let routing = CloudSecretsProviderRouting(effectiveNames: plan.effective.keys)
        return needsProviderRouting(routing, plan: plan)
    }

    /// Runs the routing guard on the machine. Names and constants only.
    @discardableResult
    func applyProviderRouting(_ routing: CloudSecretsProviderRouting, machineID: String) async throws -> CloudSecretsProviderRouting.GuardResult {
        try await routing.apply(machineID: machineID, exec: transport.exec)
    }
}

extension CloudSecretsProviderRouting {
    /// The routing that protects the provider keys among `names`, which are about
    /// to be written into a machine's env outside Cloud Secrets (`vm.env_set`), or
    /// nil when there are none. It never releases anything: endpoints for every
    /// other provider are kept as they are.
    init?<Names: Sequence>(protectingNames names: Names) where Names.Element == String {
        let routing = CloudSecretsProviderRouting(effectiveNames: names).protectingOnly
        guard routing.hasUserProviderKey else { return nil }
        self = routing
    }

    /// Runs this routing's guard on the machine over `exec` (names and constants
    /// only) and returns, per provider, whether its keys may land. Throws only when
    /// the guard could not run at all (a transport error, a shim too old).
    func apply(
        machineID: String,
        exec: @Sendable (_ machineID: String, _ command: String) async throws -> VMExecResult
    ) async throws -> GuardResult {
        let result = try await exec(machineID, command)
        return try GuardResult(result, machineID: machineID)
    }

    /// Delivers `entries` to a machine outside Cloud Secrets (`vm.env_set`): when
    /// any is a provider key, the guard runs first. Every entry it does not hold
    /// back is delivered; a held-back key is then reported as an error naming it
    /// and why. The one guarded path for writes that name a provider key.
    @discardableResult
    static func deliverGuarded<Outcome: Sendable>(
        machineID: String,
        entries: [CloudEnvDelivery.Entry],
        exec: @Sendable (_ machineID: String, _ command: String) async throws -> VMExecResult,
        deliver: @Sendable ([CloudEnvDelivery.Entry]) async throws -> Outcome
    ) async throws -> Outcome {
        guard let routing = CloudSecretsProviderRouting(protectingNames: entries.map(\.key)) else {
            return try await deliver(entries)
        }
        let heldBack = try await routing.apply(machineID: machineID, exec: exec).heldBack(names: entries.map(\.key))
        guard !heldBack.isEmpty else { return try await deliver(entries) }
        let safe = entries.filter { heldBack[$0.key] == nil }
        if !safe.isEmpty { _ = try await deliver(safe) }
        throw HeldBackError(message: heldBackMessage(heldBack, retries: false))
    }

    // MARK: Guard results

    /// Why the guard could not route a provider, so its keys must not land yet.
    enum HoldReason: Equatable, Hashable, Sendable {
        /// The provider's own endpoint could not be written to the machine env.
        case env
        /// The machine's model-plane copy could not be neutralized.
        case planeCopy
        /// Codex's config could not be switched to the user's key.
        case codex
        /// OpenCode's provider file could not be secured.
        case opencode
        /// The guard reported a cause this build does not know.
        case other
        /// The guard ended without a result.
        case noResult(exitCode: Int)

        init(token: String) {
            switch token {
            case "env": self = .env
            case "plane-copy": self = .planeCopy
            case "codex": self = .codex
            case "opencode": self = .opencode
            default: self = .other
            }
        }

        var explanation: String {
            switch self {
            case .env:
                return String(localized: "cloudSecrets.routing.hold.env", defaultValue: "the machine env could not name the provider's own endpoint")
            case .planeCopy:
                return String(localized: "cloudSecrets.routing.hold.planeCopy", defaultValue: "the machine's model routing file could not be locked against copies of your key")
            case .codex:
                return String(localized: "cloudSecrets.routing.hold.codex", defaultValue: "Codex's config on the machine could not be switched to your key")
            case .opencode:
                return String(localized: "cloudSecrets.routing.hold.opencode", defaultValue: "OpenCode's provider file on the machine could not be secured")
            case .other:
                return String(localized: "cloudSecrets.routing.hold.other", defaultValue: "the machine could not route the provider's traffic away from cmux model routing")
            case .noResult(let exitCode):
                return String(
                    format: String(localized: "cloudSecrets.routing.hold.noResult", defaultValue: "the routing check on the machine ended without a result (exit %ld)"),
                    exitCode
                )
            }
        }
    }

    /// The guard's per-provider answer. nil means routed.
    struct GuardResult: Equatable, Sendable {
        var openAI: HoldReason?
        var anthropic: HoldReason?

        static let resultPrefix = "CMUX-ROUTING-RESULT "

        init(openAI: HoldReason?, anthropic: HoldReason?) {
            self.openAI = openAI
            self.anthropic = anthropic
        }

        /// Parses the guard's one result line. Without one (or with a failed exit),
        /// every provider is held back: no provider key lands on a machine whose
        /// routing is unknown.
        init(_ result: VMExecResult, machineID: String) throws {
            let text = result.stdout + "\n" + result.stderr
            if text.contains("unknown resource scope") || text.contains("unknown vm subcommand") {
                throw CloudEnvDelivery.DeliveryError.outdatedShim(machineID)
            }
            // The guard always exits 0 after its result; any other exit means it did
            // not finish, whatever it printed.
            guard result.exitCode == 0, let line = result.stdout.split(whereSeparator: \.isNewline)
                .last(where: { $0.hasPrefix(Self.resultPrefix) }) else {
                let reason = HoldReason.noResult(exitCode: result.exitCode)
                self.init(openAI: reason, anthropic: reason)
                return
            }
            var fields: [String: String] = [:]
            for field in line.dropFirst(Self.resultPrefix.count).split(separator: " ") {
                let pair = field.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            func reason(_ name: String) -> HoldReason? {
                guard let token = fields[name] else { return .other }
                return token == "ok" ? nil : HoldReason(token: token)
            }
            self.init(openAI: reason("openai"), anthropic: reason("anthropic"))
        }

        /// True when every provider was routed.
        var isRouted: Bool { openAI == nil && anthropic == nil }

        /// The provider keys among `names` that must wait, with why.
        func heldBack<Names: Sequence>(names: Names) -> [String: HoldReason] where Names.Element == String {
            var held: [String: HoldReason] = [:]
            for name in names {
                if let openAI, CloudSecretsProviderRouting.openAIKeyNames.contains(name) { held[name] = openAI }
                if let anthropic, CloudSecretsProviderRouting.anthropicKeyNames.contains(name) { held[name] = anthropic }
            }
            return held
        }
    }

    /// A key `vm.env_set` held back; the message names it and why, never a value.
    struct HeldBackError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Human text for held-back keys: one sentence per cause, names only.
    static func heldBackMessage(_ heldBack: [String: HoldReason], retries: Bool) -> String {
        var byReason: [HoldReason: [String]] = [:]
        for (name, reason) in heldBack { byReason[reason, default: []].append(name) }
        let sentences = byReason
            .map { (names: $0.value.sorted(), reason: $0.key) }
            .sorted { $0.names.first ?? "" < $1.names.first ?? "" }
            .map { group -> String in
                let names = group.names.joined(separator: ", ")
                let format = retries
                    ? String(localized: "cloudSecrets.routing.heldBack.retry", defaultValue: "%1$@ held back from this machine: %2$@. Your other secrets were delivered; cmux tries again on the next sync.")
                    : String(localized: "cloudSecrets.routing.heldBack.envSet", defaultValue: "%1$@ was not set on this machine: %2$@. Every other variable was set.")
                return String(format: format, names, group.reason.explanation)
            }
        return sentences.joined(separator: " ")
    }
}
