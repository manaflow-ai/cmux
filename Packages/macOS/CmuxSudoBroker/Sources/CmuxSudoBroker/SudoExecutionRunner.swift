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
    private let reviewedScriptReader: SudoReviewedScriptReader
    private let expectedParentExecutableURL: URL
    private let privilegedHelperExecutableURL: URL
    private let messages: SudoFailureMessages
    private let now: @Sendable () -> Date

    /// Creates the production runner used by the hidden bundled-CLI entrypoint.
    ///
    /// - Parameters:
    ///   - paths: The enclosing app bundle's private sudo spool.
    ///   - expectedParentExecutableURL: The enclosing cmux GUI executable.
    ///   - privilegedHelperExecutableURL: The bundled CLI re-entered after authentication.
    ///   - messages: Localized terminal diagnostics persisted with results.
    ///   - pamConfiguration: The sudo PAM policy reader.
    public init(
        paths: SudoBrokerPaths,
        expectedParentExecutableURL: URL,
        privilegedHelperExecutableURL: URL,
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
        reviewedScriptReader = SudoReviewedScriptReader()
        processRunner = SudoBoundedProcessRunner(
            spawner: spawner,
            inspector: inspector,
            signaler: signaler
        )
        self.expectedParentExecutableURL = expectedParentExecutableURL
        self.privilegedHelperExecutableURL = privilegedHelperExecutableURL
        self.messages = messages
        now = { .now }
    }

    init(
        store: SudoSpoolStore,
        pam: any SudoPAMChecking,
        inspector: any SudoProcessInspecting,
        parentValidator: SudoRunnerParentValidator,
        processRunner: SudoBoundedProcessRunner,
        reviewedScriptReader: SudoReviewedScriptReader = SudoReviewedScriptReader(),
        expectedParentExecutableURL: URL,
        privilegedHelperExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/false"),
        messages: SudoFailureMessages,
        now: @Sendable @escaping () -> Date
    ) {
        self.store = store
        self.pam = pam
        self.inspector = inspector
        self.parentValidator = parentValidator
        self.processRunner = processRunner
        self.reviewedScriptReader = reviewedScriptReader
        self.expectedParentExecutableURL = expectedParentExecutableURL
        self.privilegedHelperExecutableURL = privilegedHelperExecutableURL
        self.messages = messages
        self.now = now
    }

    /// Executes one approved request and persists exactly one terminal result.
    ///
    /// - Parameter requestID: The approved request identifier supplied by the app.
    /// - Returns: Zero after a terminal result is persisted, or a runner setup error code.
    public func run(requestID: String) -> Int32 {
        run(requestID: requestID, expectedManifestData: nil)
    }

    /// Executes one approved request while optionally binding the runner to a serialized manifest.
    ///
    /// When ``expectedManifestData`` is provided, it must decode to the exact manifest currently
    /// stored for ``requestID``. The runner rejects malformed, stale, or raced manifests before
    /// claiming execution, preserving the cross-process capability binding.
    ///
    /// - Parameters:
    ///   - requestID: The approved request identifier supplied by the app.
    ///   - expectedManifestData: An ISO 8601 JSON encoding of the expected execution manifest.
    /// - Returns: Zero after a terminal result is persisted, or a runner setup error code.
    public func run(requestID: String, expectedManifestData: Data?) -> Int32 {
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
            let reviewedScript: Data
            do {
                reviewedScript = try reviewedScriptReader.read()
            } catch {
                try settleRunnerLaunchFailureIfApproved(
                    requestID: requestID,
                    auditStatus: "failed reviewed-script-capability"
                )
                return 1
            }
            let expectedManifest: SudoExecutionManifest?
            if let expectedManifestData {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let decodedManifest = try? decoder.decode(
                    SudoExecutionManifest.self,
                    from: expectedManifestData
                ) else {
                    try settleRunnerLaunchFailureIfApproved(
                        requestID: requestID,
                        auditStatus: "failed manifest-capability"
                    )
                    return 1
                }
                expectedManifest = decodedManifest
                guard store.manifest(id: requestID) == decodedManifest else {
                    try settleRunnerLaunchFailureIfApproved(
                        requestID: requestID,
                        auditStatus: "failed manifest-binding"
                    )
                    return 1
                }
            } else {
                expectedManifest = nil
            }
            guard let manifest = try store.claimApprovedExecution(
                id: requestID,
                runner: runnerIdentity,
                now: startedAt,
                expectedManifest: expectedManifest
            ) else {
                return 0
            }
            if let expectedManifest, expectedManifest != manifest {
                try settleRunnerLaunchFailureIfApproved(
                    requestID: requestID,
                    auditStatus: "failed manifest-race"
                )
                return 1
            }

            guard inspector.isRunning(manifest.requesterIdentity) else {
                try settle(
                    SudoResult(
                        id: requestID,
                        status: .failed,
                        errorCode: .requesterUnavailable,
                        note: messages.requesterUnavailable
                    ),
                    auditStatus: "failed requester-validation"
                )
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
                reviewedScript: reviewedScript,
                privilegedHelperExecutableURL: privilegedHelperExecutableURL,
                deadline: manifest.deadline,
                currentDirectoryURL: URL(
                    fileURLWithPath: manifest.currentDirectory,
                    isDirectory: true
                ),
                outputURL: store.outputURL(id: requestID),
                directoryIdentity: manifest.directoryIdentity
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
                    let survivors = processRunner.terminate(process)
                    recordCleanupSurvivors(survivors, requestID: requestID)
                    return 0
                }
            } catch {
                let survivors = processRunner.terminate(process)
                recordCleanupSurvivors(survivors, requestID: requestID)
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

            let outcome = processRunner.wait(
                for: process,
                deadline: manifest.deadline.addingTimeInterval(
                    store.resourcePolicy.privilegedCleanupGraceSeconds
                )
            )
            let cleanupSurvivors: [SudoProcessIdentity]
            switch outcome {
            case .authenticationFailed(let survivors), .timedOut(let survivors):
                cleanupSurvivors = survivors
            case .exited, .signaled, .unavailable, .privilegedTimedOut,
                    .privilegedTransportFailed:
                cleanupSurvivors = []
            case .privilegedCleanupFailed(let survivors):
                cleanupSurvivors = survivors
            }
            recordCleanupSurvivors(cleanupSurvivors, requestID: requestID)
            try settle(
                result(
                    requestID: requestID,
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
        outcome: SudoProcessOutcome
    ) -> SudoResult {
        switch outcome {
        case .exited(let exitCode):
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
        case .unavailable:
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: .executionInterrupted,
                note: messages.executionInterrupted
            )
        case .authenticationFailed(let survivors):
            let cleanupFailed = !survivors.isEmpty
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: cleanupFailed ? .processCleanupFailed : .authenticationFailed,
                note: cleanupFailed ? messages.cleanupFailed : messages.authenticationFailed
            )
        case .timedOut(let survivors):
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: survivors.isEmpty ? .executionTimedOut : .processCleanupFailed,
                note: survivors.isEmpty ? messages.executionTimedOut : messages.cleanupFailed
            )
        case .privilegedTimedOut:
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: .executionTimedOut,
                note: messages.executionTimedOut
            )
        case .privilegedCleanupFailed(_):
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: .processCleanupFailed,
                note: messages.cleanupFailed
            )
        case .privilegedTransportFailed:
            return SudoResult(
                id: requestID,
                status: .failed,
                errorCode: .processLaunchFailed,
                note: messages.processLaunchFailed
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

    private func recordCleanupSurvivors(
        _ survivors: [SudoProcessIdentity],
        requestID: String
    ) {
        guard !survivors.isEmpty else { return }
        _ = try? store.recordCleanupSurvivors(
            id: requestID,
            survivors: survivors,
            now: now()
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
