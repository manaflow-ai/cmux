import Foundation

/// Checks the account and kernel lock of an already planned Codex resume.
///
/// Both the CLI execution boundary and Vault use this policy. It is advisory:
/// Codex must still acquire its own lock atomically after cmux releases the probe.
/// The synchronous API supports exec-based CLI callers; UI callers must run the
/// bounded filesystem/process inspection outside the main actor.
public struct CodexWriterRestorePreflight: Sendable {
    private let lockInspector: CodexWriterLockInspector
    private let ownerLookup: @Sendable (CodexWriterLockInspection) -> CodexWriterOwnerScan

    /// Creates a preflight using read-only kernel process and file inspection.
    /// - Parameter ownerLookup: Descriptor discovery dependency, called only for an active lock.
    public init(
        ownerLookup: @escaping @Sendable (CodexWriterLockInspection) -> CodexWriterOwnerScan = { CodexWriterProcessInspector().owners(for: $0) }
    ) {
        lockInspector = CodexWriterLockInspector()
        self.ownerLookup = ownerLookup
    }

    /// Inspects the effective launch, never the app's ambient account or a saved tty label.
    ///
    /// - Parameters:
    ///   - sessionID: The validated thread UUID to resume.
    ///   - arguments: Final process argv, including the executable.
    ///   - environment: Complete environment the child will actually receive.
    ///   - workingDirectory: Actual cwd after applying the saved directory fallback.
    ///   - verificationHome: User home captured with the launch, used when the
    ///     environment names no `CODEX_HOME`.
    ///   - fallbackHome: User home when neither the environment nor the capture names one.
    /// - Returns: The local lock and holder evidence, or no inspection for remote Codex.
    public func inspect(
        sessionID: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        verificationHome: String? = nil,
        fallbackHome: String
    ) -> CodexWriterRestoreInspection {
        guard !usesRemoteProvider(arguments: arguments) else {
            return CodexWriterRestoreInspection(lock: nil, owners: [])
        }
        // One resolver for verification, restore, and this probe, so the lock
        // that is inspected belongs to the account the child will use.
        let home = CodexHomeResolver().resolve(
            launchEnvironment: environment,
            launchWorkingDirectory: workingDirectory,
            launchVerificationHome: verificationHome,
            ambientEnvironment: environment,
            fallbackHomeDirectory: fallbackHome
        )
        let first = lockInspector.inspect(sessionID: sessionID, codexHome: home)
        guard first.state == .active else {
            return CodexWriterRestoreInspection(lock: first, owners: [])
        }
        let scan = ownerLookup(first)
        // The writer can exit while descriptors are being inspected. Never
        // navigate or block based on a lock that has since been released.
        let current = lockInspector.inspect(sessionID: sessionID, codexHome: home)
        let sameLock = current.state == .active
            && current.device == first.device && current.inode == first.inode
        return CodexWriterRestoreInspection(
            lock: current, owners: sameLock ? scan.owners : [], ownerScanComplete: sameLock && scan.isComplete
        )
    }

    /// Recognizes the remote endpoint option without interpreting option values or prompts as flags.
    /// - Parameter arguments: Codex argv, including the executable.
    /// - Returns: Whether ownership belongs to a remote app-server, not the local home.
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
