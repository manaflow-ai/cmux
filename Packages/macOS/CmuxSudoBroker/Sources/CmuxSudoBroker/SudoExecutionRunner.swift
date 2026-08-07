import Darwin
public import Foundation

/// Runs one approved sudo manifest under an independent process-tree deadline.
public struct SudoExecutionRunner {
    /// The private bundled-CLI command used only by ``SudoBroker``.
    public static let hiddenCommand = "__cmux-sudo-runner"

    private let store: SudoSpoolStore
    private let pam: any SudoPAMChecking
    private let inspector: any SudoProcessInspecting
    private let parentValidator: SudoRunnerParentValidator
    private let processRunner: SudoBoundedProcessRunner
    private let expectedParentExecutableURL: URL
    private let messages: SudoFailureMessages
    private let outputDetector: SudoAuthenticationOutputDetector
    private let now: @Sendable () -> Date

    /// Creates the production runner used by the hidden bundled-CLI entrypoint.
    ///
    /// - Parameters:
    ///   - paths: The enclosing app bundle's private sudo spool.
    ///   - expectedParentExecutableURL: The enclosing cmux GUI executable.
    ///   - messages: Localized terminal diagnostics persisted with results.
    ///   - pamConfiguration: The sudo PAM policy reader.
    public init(
        paths: SudoBrokerPaths,
        expectedParentExecutableURL: URL,
        messages: SudoFailureMessages,
        pamConfiguration: SudoPAMConfiguration = SudoPAMConfiguration()
    ) {
        let inspector = SystemSudoProcessInspector()
        let signaler = SystemSudoProcessSignaler()
        let spawner = SudoPOSIXProcessSpawner(inspector: inspector)
        store = SudoSpoolStore(paths: paths)
        pam = pamConfiguration
        self.inspector = inspector
        parentValidator = SudoRunnerParentValidator(inspector: inspector)
        processRunner = SudoBoundedProcessRunner(
            spawner: spawner,
            inspector: inspector,
            signaler: signaler
        )
        self.expectedParentExecutableURL = expectedParentExecutableURL
        self.messages = messages
        outputDetector = SudoAuthenticationOutputDetector()
        now = { .now }
    }

    init(
        store: SudoSpoolStore,
        pam: any SudoPAMChecking,
        inspector: any SudoProcessInspecting,
        parentValidator: SudoRunnerParentValidator,
        processRunner: SudoBoundedProcessRunner,
        expectedParentExecutableURL: URL,
        messages: SudoFailureMessages,
        outputDetector: SudoAuthenticationOutputDetector = SudoAuthenticationOutputDetector(),
        now: @Sendable @escaping () -> Date
    ) {
        self.store = store
        self.pam = pam
        self.inspector = inspector
        self.parentValidator = parentValidator
        self.processRunner = processRunner
        self.expectedParentExecutableURL = expectedParentExecutableURL
        self.messages = messages
        self.outputDetector = outputDetector
        self.now = now
    }

    /// Executes one approved request and persists exactly one terminal result.
    ///
    /// - Parameter requestID: The approved request identifier supplied by the app.
    /// - Returns: Zero after a terminal result is persisted, or a runner setup error code.
    public func run(requestID: String) -> Int32 {
        do {
            try store.ensureDirectories()
            guard parentValidator.validate(expectedExecutableURL: expectedParentExecutableURL) else {
                try settleRunnerLaunchFailureIfApproved(
                    requestID: requestID,
                    auditStatus: "failed runner-parent-validation"
                )
                return 126
            }
            let startedAt = now()
            guard let runnerIdentity = inspector.identity(for: getpid()) else {
                try settleRunnerLaunchFailureIfApproved(
                    requestID: requestID,
                    auditStatus: "failed runner-identity"
                )
                return 1
            }
            guard let manifest = try store.claimApprovedExecution(
                id: requestID,
                runner: runnerIdentity,
                now: startedAt
            ) else {
                return 0
            }

            guard pam.touchIDIsEnabled() else {
                try settle(
                    SudoResult(
                        id: requestID,
                        status: .failed,
                        errorCode: .pamTidUnavailable,
                        note: messages.pamTidUnavailable
                    ),
                    auditStatus: "failed pam-preflight"
                )
                return 0
            }

            guard manifest.deadline > startedAt else {
                try settle(
                    SudoResult(
                        id: requestID,
                        status: .failed,
                        errorCode: .executionTimedOut,
                        note: messages.executionTimedOut
                    ),
                    auditStatus: "failed deadline-before-spawn"
                )
                return 0
            }

            let command = SudoExecutionCommand.sudo(
                approvedScriptURL: store.approvedScriptURL(id: requestID),
                currentDirectoryURL: URL(
                    fileURLWithPath: manifest.currentDirectory,
                    isDirectory: true
                ),
                outputURL: store.outputURL(id: requestID)
            )
            let process: SudoSpawnedProcess
            do {
                process = try processRunner.spawn(command)
            } catch {
                try settle(
                    SudoResult(
                        id: requestID,
                        status: .failed,
                        errorCode: .processLaunchFailed,
                        note: messages.processLaunchFailed
                    ),
                    auditStatus: "failed process-launch"
                )
                return 0
            }

            do {
                guard try store.recordExecutionIdentity(
                    id: requestID,
                    execution: process.identity,
                    now: now()
                ) else {
                    _ = processRunner.terminate(process)
                    return 0
                }
            } catch {
                let survivors = processRunner.terminate(process)
                if !survivors.isEmpty {
                    _ = try? store.recordCleanupSurvivors(
                        id: requestID,
                        survivors: survivors,
                        now: now()
                    )
                }
                try settle(
                    SudoResult(
                        id: requestID,
                        status: .failed,
                        errorCode: survivors.isEmpty ? .runnerLaunchFailed : .processCleanupFailed,
                        note: survivors.isEmpty ? messages.runnerLaunchFailed : messages.cleanupFailed
                    ),
                    auditStatus: survivors.isEmpty
                        ? "failed execution-state"
                        : "failed execution-state-cleanup"
                )
                return 1
            }

            let outcome = processRunner.wait(for: process, deadline: manifest.deadline)
            if case .timedOut(let survivors) = outcome, !survivors.isEmpty {
                _ = try? store.recordCleanupSurvivors(
                    id: requestID,
                    survivors: survivors,
                    now: now()
                )
            }
            try settle(
                result(
                    requestID: requestID,
                    outputURL: command.outputURL,
                    outcome: outcome
                ),
                auditStatus: "execution-finished"
            )
            return 0
        } catch {
            try? settle(
                SudoResult(
                    id: requestID,
                    status: .failed,
                    errorCode: .runnerLaunchFailed,
                    note: messages.runnerLaunchFailed
                ),
                auditStatus: "failed runner-internal"
            )
            return 1
        }
    }

    private func result(
        requestID: String,
        outputURL: URL,
        outcome: SudoProcessOutcome
    ) -> SudoResult {
        switch outcome {
        case .exited(let exitCode):
            if exitCode != 0,
               outputDetector.indicatesAuthenticationFailure(at: outputURL) {
                return SudoResult(
                    id: requestID,
                    status: .failed,
                    exitCode: exitCode,
                    errorCode: .authenticationFailed,
                    note: messages.authenticationFailed
                )
            }
            return SudoResult(
                id: requestID,
                status: .completed,
                exitCode: exitCode
            )
        case .signaled:
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: .executionInterrupted,
                note: messages.executionInterrupted
            )
        case .timedOut(let survivors):
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: survivors.isEmpty ? .executionTimedOut : .processCleanupFailed,
                note: survivors.isEmpty ? messages.executionTimedOut : messages.cleanupFailed
            )
        }
    }

    private func settle(
        _ result: SudoResult,
        auditStatus: String
    ) throws {
        _ = try store.settle(result)
        store.appendAudit(
            "\(now().ISO8601Format()) \(result.id) \(auditStatus)"
        )
    }

    private func settleRunnerLaunchFailureIfApproved(
        requestID: String,
        auditStatus: String
    ) throws {
        guard store.state(id: requestID)?.phase == .approved,
              store.result(id: requestID) == nil else {
            return
        }
        try settle(
            SudoResult(
                id: requestID,
                status: .failed,
                errorCode: .runnerLaunchFailed,
                note: messages.runnerLaunchFailed
            ),
            auditStatus: auditStatus
        )
    }
}
