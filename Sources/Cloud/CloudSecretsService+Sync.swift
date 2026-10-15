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

    /// `git config` for a helper that reads the token from the environment at use time,
    /// so no value is ever in argv, a config file, or the exec channel.
    nonisolated static var gitCredentialHelperCommand: String {
        let helper = #"!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=${GH_TOKEN:-$GITHUB_TOKEN}"; }; f"#
        return ["git", "config", "--global", "credential.https://github.com.helper", helper]
            .map(\.posixShellWord)
            .joined(separator: " ")
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
            return failure(machineID: machineID, error: error, values: [])
        }
        let values = plan.toSend.map(\.value)
        let routing = CloudSecretsProviderRouting(effectiveNames: plan.effective.keys)
        let routesMachine = needsProviderRouting(routing, plan: plan)
        if plan.isNoop {
            // A machine the ledger has never seen gets an entry, so later changes to
            // the `all` scope reach it through ``syncAllStale()``.
            do {
                if routesMachine {
                    try await applyProviderRouting(routing, machineID: machineID)
                    recordProviderRouting(routing, machineID: machineID)
                }
                if try await vault.delivery(for: machineID) == nil {
                    try await vault.recordDelivered(machineID: machineID, plan: plan, at: Date())
                    await reload()
                    postDidChange()
                }
            } catch {
                return failure(machineID: machineID, error: error, values: values)
            }
            return CloudSecretSyncResult(
                machineID: machineID, sent: [], removed: [], noop: true,
                configuredGitCredentials: false, error: nil
            )
        }
        var configuredGit = false
        do {
            if routesMachine, routing.hasUserProviderKey {
                try await applyProviderRouting(routing.protectingOnly, machineID: machineID)
            }
            if !plan.toSend.isEmpty {
                try await transport.deliver(machineID, plan.toSend)
            }
            if !plan.toRemove.isEmpty {
                let result = try await transport.exec(machineID, Self.envRemoveCommand(names: plan.toRemove))
                try Self.requireShimSuccess(result, machineID: machineID)
            }
            if routesMachine {
                if routing.releasesEndpoint {
                    try await applyProviderRouting(routing, machineID: machineID)
                }
                recordProviderRouting(routing, machineID: machineID)
            }
            if !plan.toSend.isEmpty, !Self.gitTokenNames.isDisjoint(with: plan.sendNames) {
                // Best effort: the token itself is delivered; only `git push` over
                // HTTPS depends on the helper, and `gh auth setup-git` remains a fallback.
                if let result = try? await transport.exec(machineID, Self.gitCredentialHelperCommand),
                   result.exitCode == 0 {
                    configuredGit = true
                }
            }
            try await vault.recordDelivered(machineID: machineID, plan: plan, at: Date())
        } catch {
            return failure(machineID: machineID, error: error, values: values)
        }
        await reload()
        postDidChange()
        return CloudSecretSyncResult(
            machineID: machineID,
            sent: plan.sendNames,
            removed: plan.toRemove,
            noop: false,
            configuredGitCredentials: configuredGit,
            error: nil
        )
    }

    private func failure(machineID: String, error: Error, values: [String]) -> CloudSecretSyncResult {
        let message = Self.redactedMessage(for: error, values: values)
#if DEBUG
        cmuxDebugLog("cloudSecrets.sync.failed machine=\(machineID) error=\(type(of: error))")
#endif
        Task { @MainActor in
            try? await self.vault.recordFailure(machineID: machineID, message: message)
            await self.reload()
            self.postDidChange()
        }
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
            case .outdatedShim, .invalidKey, .multilineValue, .tooLarge, .emptyPayload, .workspaceCleanupFailed:
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
set -u
openai=${1:-keep}
anthropic=${2:-keep}
user_key() { [ "$1" = direct ] || [ "$1" = user ]; }
etc=${CMUX_ROUTING_ETC:-/etc/cmux}
home=${HOME:-/root}
envf="$home/.config/cmux/env"
placeholder=cmux-vm-edge-placeholder
status=0
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
    { mkdir -p "$home/.config/cmux" && ln -sfn /dev/null "$mp"; } || status=1
  fi
elif [ -f "$mp" ]; then
  {
    grep -v -E "^export (OPENAI|ANTHROPIC)_API_KEY=" "$mp" || :
    grep -x -E "export (OPENAI|ANTHROPIC)_API_KEY='$placeholder'" "$mp" || :
  } > "$mp.cmux-tmp" && chmod 600 "$mp.cmux-tmp" && mv -f "$mp.cmux-tmp" "$mp" || status=1
fi

# 2. Beside a user's key with no endpoint of their own, the provider's own
# endpoint; a cmux-added endpoint goes when the key does.
route() {
  current=$(sed -n "s/^export $2='\(.*\)'\$/\1/p" "$envf" 2>/dev/null | tail -n 1)
  case "$1" in
    direct)
      if [ -z "$current" ] || { [ -n "$plane" ] && { [ "${current%/}" = "$plane" ] || [ "${current#"$plane"/}" != "$current" ]; }; }; then
        cmux env set "$2=$3" >/dev/null 2>&1 || status=1
      fi
      ;;
    plane)
      if [ "$current" = "$3" ]; then cmux env rm "$2" >/dev/null 2>&1 || status=1; fi
      ;;
  esac
}
route "$openai" OPENAI_BASE_URL https://api.openai.com/v1
route "$anthropic" ANTHROPIC_BASE_URL https://api.anthropic.com

# The image's agent-config, run in a shell that carries only the baked plane
# (as the machine's first login shell does), then $1. Its writes to the
# model-plane copy land in /dev/null (step 1).
plane_shell() {
  [ -f "$etc/agent-config.sh" ] && [ -f "$etc/model-plane.env" ] || return 0
  bash -c 'unset OPENAI_BASE_URL OPENAI_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; . "$1/model-plane.env"; . "$1/agent-config.sh"; '"$1" \
    cmux-routing "$etc" </dev/null >/dev/null 2>&1 || :
}

# 3. codex: a cmux-generated config names the model router as its provider
# and authenticates it with OPENAI_API_KEY. Launchers older than the
# per-launch precedence get the user's key provider in the file instead.
# A brand-new machine whose first sync runs before its first shell has no
# config yet; the first shell would write the model router's provider, so
# write it now and switch it below.
codex_cfg="${CODEX_HOME:-$home/.codex}/config.toml"
if user_key "$openai" && ! grep -qs '^model_provider' "$codex_cfg"; then plane_shell :; fi
if [ -f "$codex_cfg" ] && ! grep -qs cmux_codex_user_key_provider "$etc/agent-auth.sh"; then
  if user_key "$openai"; then
    if grep -qx 'model_provider = "cmux"' "$codex_cfg"; then
      {
        sed 's/^model_provider = "cmux"$/model_provider = "cmux-openai-key"/' "$codex_cfg"
        if ! grep -qx '\[model_providers\.cmux-openai-key\]' "$codex_cfg"; then
          printf '\n# Cloud Secrets: your own OPENAI_API_KEY goes to OpenAI directly.\n[model_providers.cmux-openai-key]\nname = "OpenAI"\nbase_url = "https://api.openai.com/v1"\nenv_key = "OPENAI_API_KEY"\nwire_api = "responses"\n'
        fi
      } > "$codex_cfg.cmux-tmp" && mv -f "$codex_cfg.cmux-tmp" "$codex_cfg" || status=1
    fi
  elif [ "$openai" = plane ] && grep -qx 'model_provider = "cmux-openai-key"' "$codex_cfg"; then
    sed 's/^model_provider = "cmux-openai-key"$/model_provider = "cmux"/' "$codex_cfg" > "$codex_cfg.cmux-tmp" \
      && mv -f "$codex_cfg.cmux-tmp" "$codex_cfg" || status=1
  fi
fi

# 4. OpenCode: the image writes the model router's providers with
# {env:OPENAI_API_KEY} as their key, which is the user's key once they have
# one, and its launch fetches them with OPENAI_API_KEY as the credential.
# Fetch them now in a plane-only shell (the placeholder), so a launch finds
# them in place, then give those providers the public placeholder.
if user_key "$openai" && [ -n "$plane" ] && grep -qs 'os.environ\["OPENAI_API_KEY"\]' "$etc/agent-config.sh"; then
  plane_shell cmux_ensure_opencode_config
fi
if command -v python3 >/dev/null 2>&1; then
  python3 - "$plane" "$home/.config/cmux/opencode-team.json" "${XDG_CONFIG_HOME:-$home/.config}/opencode/opencode.json" <<'CMUX_OPENCODE_ROUTING' || status=1
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
exit "$status"
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

    func recordProviderRouting(_ routing: CloudSecretsProviderRouting, machineID: String) {
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
    func applyProviderRouting(_ routing: CloudSecretsProviderRouting, machineID: String) async throws {
        let result = try await transport.exec(machineID, routing.command)
        try Self.requireShimSuccess(result, machineID: machineID)
    }
}
