import CmuxSimulator
import Darwin
import Foundation

struct SimulatorToolOperationContainment {
    let cancellationGrace: Duration
    let terminate: @MainActor @Sendable () -> Void

    init(
        cancellationGrace: Duration = .milliseconds(250),
        terminate: @escaping @MainActor @Sendable () -> Void = { _exit(87) }
    ) {
        self.cancellationGrace = cancellationGrace
        self.terminate = terminate
    }
}

extension SimulatorWorkerCoordinator {
    convenience init(
        channel: SimulatorLengthPrefixedMessageChannel,
        toolOperationSleeper: any SimulatorHIDSleeping,
        toolOperationCancellationGrace: Duration,
        toolOperationTerminator: @escaping @MainActor @Sendable () -> Void
    ) {
        self.init(
            channel: channel,
            toolOperationSleeper: toolOperationSleeper,
            toolOperationContainment: SimulatorToolOperationContainment(
                cancellationGrace: toolOperationCancellationGrace,
                terminate: toolOperationTerminator
            )
        )
    }
}
