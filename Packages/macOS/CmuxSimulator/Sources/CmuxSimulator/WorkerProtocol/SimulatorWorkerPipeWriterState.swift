import Foundation

/// Synchronous coordination shared by producer closures and the writer thread.
///
/// An actor would make the synchronous send boundary reentrant. This state
/// keeps frame ordering and blocking descriptor work on the dedicated thread.
final class SimulatorWorkerPipeWriterState: @unchecked Sendable {
    let condition = NSCondition()
    let writeFD: Int32
    let writeDeadline: Duration
    let failureHandler: @Sendable () -> Void
    var payloads: [Data] = []
    var outstandingCount = 0
    var finishHandler: (@Sendable () -> Void)?
    var isFinishing = false
    var isStopping = false
    var isPoisoned = false
    var didExit = false

    init(
        writeFD: Int32,
        writeDeadline: Duration,
        failureHandler: @escaping @Sendable () -> Void
    ) {
        self.writeFD = writeFD
        self.writeDeadline = writeDeadline
        self.failureHandler = failureHandler
    }
}
