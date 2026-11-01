import Foundation

/// The environment changes needed to move a Claude pane to another account and resume its session.
public struct ClaudeAccountSwitchPlan: Equatable, Sendable {
    public let sessionID: String
    public let workingDirectory: String
    public let source: ClaudeAccount
    public let target: ClaudeAccount
    /// Absolute source config directory; the default account is `<home>/.claude`.
    public let sourceConfigDirectory: String
    /// Absolute target config directory; the default account is `<home>/.claude`.
    public let targetConfigDirectory: String
    /// Always exactly `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR`; "" clears a key.
    public let surfaceEnvironmentOverrides: [String: String]
    /// The launch environment without account keys, plus `CLAUDE_CONFIG_DIR` for a custom target.
    public let launchEnvironment: [String: String]
}

public enum ClaudeAccountSwitchRefusal: Error, Equatable, Sendable {
    case noClaudeSession
    case missingWorkingDirectory
    case unknownAccount(String)
    case sameAccount(String)
    /// The source account holds no conversation record for the session, so `claude --resume` on
    /// the target would fail. Usually nobody has sent it a message yet; a transcript missing from
    /// the account directory cmux expected lands here too.
    case noConversationYet
    /// Both accounts have a copy of the conversation and each went on without the other, so
    /// neither can replace the other without losing turns. `newerAccount` names the account whose
    /// copy was written last.
    case transcriptDiverged(newerAccount: String)
}

extension ClaudeAccountSwitchRefusal {
    /// The refusal a failed transcript preflight means, or `nil` when the failure says nothing
    /// about the conversation (an unusable session id, or an I/O error) and the switch reports
    /// the transcript as unavailable instead.
    ///
    /// - Parameters:
    ///   - error: What ``ClaudeTranscriptAccountSync/sync(_:)`` threw.
    ///   - sourceAccountName: The account the pane runs on now, named when the copies diverged.
    ///   - targetAccountName: The account the switch moves to, named when the copies diverged.
    public init?(transcriptSyncError error: any Error, sourceAccountName: String, targetAccountName: String) {
        switch error as? ClaudeTranscriptAccountSyncError {
        case .transcriptNotFound?, .noConversation?:
            self = .noConversationYet
        case .diverged(let targetIsNewer)?:
            self = .transcriptDiverged(newerAccount: targetIsNewer ? targetAccountName : sourceAccountName)
        case .invalidSessionID?, nil:
            return nil
        }
    }
}

public enum ClaudeAccountSwitchPlanner {
    private static let configKey = "CLAUDE_CONFIG_DIR"
    private static let secureStorageKey = "CLAUDE_SECURESTORAGE_CONFIG_DIR"
    /// The environment keys that select a Claude account: exactly the keys of
    /// ``ClaudeAccountSwitchPlan/surfaceEnvironmentOverrides``. Nothing else may be set on a pane
    /// for an account switch, or replayed for one.
    public static let accountEnvironmentKeys: Set<String> = [configKey, secureStorageKey]

    public static func plan(
        sessionID: String?,
        workingDirectory: String?,
        launchEnvironment: [String: String]?,
        targetName: String,
        registry: ClaudeAccountRegistry,
        homeDirectory: String
    ) -> Result<ClaudeAccountSwitchPlan, ClaudeAccountSwitchRefusal> {
        guard let sessionID, !sessionID.isEmpty else { return .failure(.noClaudeSession) }
        guard let workingDirectory, !workingDirectory.isEmpty else { return .failure(.missingWorkingDirectory) }
        guard let target = registry.account(named: targetName) else { return .failure(.unknownAccount(targetName)) }

        let source = registry.account(forEnvironment: launchEnvironment)
        let sourceDirectory = source.exhaustionKey(homeDirectory: homeDirectory)
        let targetDirectory = target.exhaustionKey(homeDirectory: homeDirectory)
        guard sourceDirectory != targetDirectory else { return .failure(.sameAccount(targetName)) }

        var environment = launchEnvironment ?? [:]
        environment[configKey] = nil
        environment[secureStorageKey] = nil
        if !target.isDefault { environment[configKey] = targetDirectory }

        return .success(ClaudeAccountSwitchPlan(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            source: source,
            target: target,
            sourceConfigDirectory: sourceDirectory,
            targetConfigDirectory: targetDirectory,
            surfaceEnvironmentOverrides: [
                configKey: target.isDefault ? "" : targetDirectory,
                secureStorageKey: "",
            ],
            launchEnvironment: environment
        ))
    }
}
