import Foundation
import os

private let cloudTerminalCreationCoordinatorLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "CloudTerminalCreation"
)

/// Executes one durable Cloud terminal creation intent.
///
/// The coordinator is deliberately independent of AppKit and ``SurfaceCatalog``:
/// tests can inject a scripted command runner, while the provider supplies the
/// live link. One correlation key spans every resolution and one attempt key is
/// reused until the daemon explicitly authorizes a replacement.
struct CloudTuiCreationCoordinator: Sendable {
    typealias Failure = CloudTuiCreationFailure

    typealias AttemptArguments = @Sendable (_ idempotencyKey: String) -> [String]

    let commandRunner: any CloudTuiCommandRunning
    let socketPath: String
    let workspaceID: String
    let command: [String]
    let onExit: String?
    let correlationKey: String
    let initialIdempotencyKey: String
    private let attemptArguments: AttemptArguments
    let clock: any Clock<Duration>
    let recoveryPolicy: CloudTuiCreationRecoveryPolicy

    init(
        commandRunner: any CloudTuiCommandRunning,
        socketPath: String,
        workspaceID: String,
        command: [String],
        onExit: String?,
        correlationKey: String,
        idempotencyKey: String,
        attemptArguments: AttemptArguments? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        recoveryPolicy: CloudTuiCreationRecoveryPolicy = .standard
    ) {
        self.commandRunner = commandRunner
        self.socketPath = socketPath
        self.workspaceID = workspaceID
        self.command = command
        self.onExit = onExit
        self.correlationKey = correlationKey
        self.initialIdempotencyKey = idempotencyKey
        self.attemptArguments = attemptArguments ?? { key in
            CloudTuiCommandLine.runArguments(
                socketPath: socketPath,
                workspaceID: workspaceID,
                command: command,
                onExit: onExit,
                idempotencyKey: key,
                correlationKey: correlationKey
            )
        }
        self.clock = clock
        self.recoveryPolicy = recoveryPolicy
    }

    /// Runs until the daemon returns a CreatedPath or a typed permanent outcome.
    func run() async throws -> CmuxTuiSnapshotParser.CreatedTerminalPath {
        var idempotencyKey = initialIdempotencyKey
        var resolutionAttempts = 0
        var reconcile = false
        while true {
            try Task.checkCancellation()
            if !reconcile {
                do {
                    let data = try await commandRunner.runTuiCommand(
                        arguments: attemptArguments(idempotencyKey),
                        deadline: .seconds(30)
                    )
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object),
                       created.workspaceID != nil || workspaceID != "current" {
                        return created
                    }
                    reconcile = true
                    cloudTerminalCreationCoordinatorLogger.notice(
                        "correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=reconcile reason=malformed-ack"
                    )
                } catch {
                    let answer = CloudTuiDaemonAnswer(error: error)
                    if answer.isCreationRequestUnsupported { throw Failure.unsupported }
                    guard answer.isCreationOutcomeAmbiguous else { throw error }
                    reconcile = true
                    cloudTerminalCreationCoordinatorLogger.notice(
                        "correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=reconcile reason=transport-or-indeterminate"
                    )
                }
            }

            do {
                let data = try await commandRunner.runTuiCommand(
                    arguments: CloudTuiCommandLine.creationResolveArguments(
                        socketPath: socketPath,
                        correlationKey: correlationKey
                    ),
                    deadline: .seconds(30)
                )
                guard let resolution = CloudTuiCreationResolution(data: data),
                      resolution.correlationKey == correlationKey,
                      (resolution.idempotencyKey == Optional(idempotencyKey)
                        || (resolution.state == .notApplied && resolution.recovery == .retryNewIdempotencyKey)) else {
                    throw Failure.outcomeUnknown
                }
                switch resolution.state {
                case .created:
                    guard let created = resolution.createdTerminal else { throw Failure.outcomeUnknown }
                    return created
                case .pending:
                    cloudTerminalCreationCoordinatorLogger.info(
                        "correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=resolve state=pending attempt=\(resolutionAttempts + 1)"
                    )
                    resolutionAttempts += 1
                    guard resolutionAttempts <= recoveryPolicy.maximumResolutionAttempts else {
                        throw Failure.outcomeUnknown
                    }
                    try await clock.sleep(for: recoveryPolicy.delay(afterAttempts: resolutionAttempts))
                case .notApplied:
                    cloudTerminalCreationCoordinatorLogger.info(
                        "correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=resolve state=not-applied recovery=\(resolution.recovery.rawValue, privacy: .public)"
                    )
                    switch resolution.recovery {
                    case .retrySameIdempotencyKey:
                        reconcile = false
                    case .retryNewIdempotencyKey:
                        idempotencyKey = "cmux-cloud-terminal-attempt-\(UUID().uuidString.lowercased())"
                        reconcile = false
                    case .wait, .none, .doNotRetry:
                        throw Failure.outcomeUnknown
                    }
                case .indeterminate:
                    cloudTerminalCreationCoordinatorLogger.error(
                        "correlation=\(correlationKey, privacy: .private(mask: .hash)) phase=resolve state=indeterminate"
                    )
                    throw Failure.outcomeUnknown
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                let answer = CloudTuiDaemonAnswer(error: error)
                if answer.isCreationResolutionUnsupported { throw Failure.unsupported }
                guard answer.isRetryable else { throw Failure.outcomeUnknown }
                resolutionAttempts += 1
                guard resolutionAttempts <= recoveryPolicy.maximumResolutionAttempts else {
                    throw Failure.outcomeUnknown
                }
                try await clock.sleep(for: recoveryPolicy.delay(afterAttempts: resolutionAttempts))
            }
        }
    }
}

private extension CloudTuiDaemonAnswer {
    var isCreationOutcomeAmbiguous: Bool {
        switch self {
        case .transportFailure, .unrecognized:
            return true
        case let .rejected(reason):
            let code = reason.lowercased()
            return code.contains("mutation.indeterminate") || code.contains("operation.failed")
        }
    }

    var isCreationResolutionUnsupported: Bool {
        switch self {
        case let .rejected(reason), let .unrecognized(reason):
            let text = reason.lowercased()
            return text == "operation.unsupported" || text.contains("unknown command")
        case .transportFailure:
            return false
        }
    }

    var isCreationRequestUnsupported: Bool {
        switch self {
        case let .rejected(reason), let .unrecognized(reason):
            let text = reason.lowercased()
            return text.contains("unknown option") || text.contains("unrecognized option") || text.contains("usage.invalid")
        case .transportFailure:
            return false
        }
    }
}
