import Foundation

/// Checks the lock in the account that the final Codex invocation will use.
///
/// This is an advisory preflight, never a reservation. Codex must acquire its
/// own writer lock after exec. Callers must not infer permission to kill a
/// process from these observations.
public struct CodexWriterRestorePreflight: Sendable {
    /// Provider-lock retry delays, totaling five seconds before reporting contention.
    public static let retryDelaysSeconds: [TimeInterval] = [0.1, 0.2, 0.4, 0.8, 1.5, 2]

    /// A blocked restore, retaining the last actual kernel observation.
    public struct Blocked: Error, Sendable {
        /// The reason the restore could not start.
        public let inspection: CodexWriterLockInspection
    }

    /// Creates a stateless restore preflight.
    public init() {}

    /// Inspects a local resume using its actual child environment and cwd.
    ///
    /// - Parameters:
    ///   - sessionID: Exact thread UUID to resume.
    ///   - arguments: Final argv, including the executable.
    ///   - environment: Complete environment the child will receive.
    ///   - workingDirectory: Actual cwd, after applying restore fallback.
    ///   - fallbackHome: User home when the child has no HOME variable.
    /// - Returns: The local lock state, or `nil` for an explicit remote provider.
    public func inspect(
        sessionID: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        fallbackHome: String
    ) -> CodexWriterLockInspection? {
        guard !usesRemoteProvider(arguments: arguments) else { return nil }
        // CODEX_HOME is a literal path in Codex, including whitespace and '~'.
        // Let the kernel resolve symlink/.. traversal rather than normalizing it.
        let explicitHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let userHome = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackHome
        let rawHome = explicitHome ?? userHome + "/.codex"
        let home = rawHome.hasPrefix("/") ? rawHome : workingDirectory + "/" + rawHome
        return CodexWriterLockInspector().inspect(sessionID: sessionID, codexHome: home)
    }

    /// Gives an exiting writer up to five seconds to release ownership.
    ///
    /// This synchronous adapter is for the exec-based CLI only. It reuses the
    /// bounded admission backoff because flock has no ownership-release event.
    /// UI callers must use ``inspect(sessionID:arguments:environment:workingDirectory:fallbackHome:)`` off-main.
    ///
    /// - Parameters:
    ///   - delays: Delays before retries; the default totals five seconds.
    ///   - sleep: Injectable CLI backoff, so tests never wait for wall-clock time.
    ///   - onRetry: Called before the first and each subsequent retry.
    ///   - inspect: Fresh lock observation on every attempt.
    /// - Throws: ``Blocked`` when inspection fails or the bounded budget expires.
    public func waitUntilAvailable(
        delays: [TimeInterval] = retryDelaysSeconds,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        onRetry: (Int) -> Void = { _ in },
        inspect: () -> CodexWriterLockInspection?
    ) throws {
        try AgentRestoreAdmissionRetry.response(
            delays: delays,
            sleep: sleep,
            onRetry: onRetry,
            isRetryable: { error in
                guard let blocked = error as? Blocked else { return false }
                return blocked.inspection.state == .active || blocked.inspection.state == .changing
            }
        ) {
            if let result = inspect(), result.state != .available {
                throw Blocked(inspection: result)
            }
        }
    }

    /// Recognizes remote ownership without mistaking option values for flags.
    /// - Parameter arguments: Final argv, including the executable.
    /// - Returns: Whether an explicit remote app-server owns the thread.
    public func usesRemoteProvider(arguments: [String]) -> Bool {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument == "--remote" || argument.hasPrefix("--remote=") { return true }
            if argument.hasPrefix("-") {
                index += AgentLaunchSanitizer.optionWidth(arguments, index: index, policy: AgentLaunchSanitizer.codexPolicy)
            } else {
                index += 1
            }
        }
        return false
    }
}
