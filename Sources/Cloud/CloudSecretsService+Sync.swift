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
    func performSync(machineID: String) async -> CloudSecretSyncResult {
        let plan: CloudSecretPlan
        do {
            plan = try await vault.plan(machineID: machineID)
        } catch {
            return failure(machineID: machineID, error: error, values: [])
        }
        let values = plan.toSend.map(\.value)
        if plan.isNoop {
            // A machine the ledger has never seen gets an entry, so later changes to
            // the `all` scope reach it through ``syncAllStale()``.
            do {
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
            if !plan.toSend.isEmpty {
                try await transport.deliver(machineID, plan.toSend)
            }
            if !plan.toRemove.isEmpty {
                let result = try await transport.exec(machineID, Self.envRemoveCommand(names: plan.toRemove))
                try Self.requireShimSuccess(result, machineID: machineID)
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
