import Darwin
import Foundation

/// Enforces parent liveness and a hard lifetime bound inside a paste worker.
///
/// Paste preparation is intentionally synchronous in the worker and can wedge
/// inside an image provider or ColorSync. Low-level dispatch sources keep both
/// safeguards independent of that blocked thread: stdin EOF proves the parent
/// disappeared, while the timer is the worker's unconditional hard deadline.
final class TerminalPastePreparationWorkerSupervisor {
    private static let maximumLifetime: DispatchTimeInterval = .seconds(10)

    private let workingDirectory: URL
    private let parentLivenessSource: DispatchSourceRead
    private let deadlineSource: DispatchSourceTimer

    init?(workingDirectory: URL) {
        let readFileDescriptor = Darwin.dup(STDIN_FILENO)
        guard readFileDescriptor >= 0 else { return nil }

        let queue = DispatchQueue.global(qos: .utility)
        let parentLivenessSource = DispatchSource.makeReadSource(
            fileDescriptor: readFileDescriptor,
            queue: queue
        )
        let deadlineSource = DispatchSource.makeTimerSource(queue: queue)
        self.workingDirectory = workingDirectory
        self.parentLivenessSource = parentLivenessSource
        self.deadlineSource = deadlineSource

        parentLivenessSource.setEventHandler { [weak self] in
            self?.handleParentLivenessEvent(readFileDescriptor)
        }
        parentLivenessSource.setCancelHandler {
            Darwin.close(readFileDescriptor)
        }
        deadlineSource.schedule(
            deadline: .now() + Self.maximumLifetime,
            leeway: .milliseconds(100)
        )
        deadlineSource.setEventHandler { [weak self] in
            self?.terminateWorker(status: 124)
        }
    }

    func start() {
        parentLivenessSource.resume()
        deadlineSource.resume()
    }

    func cancel() {
        parentLivenessSource.cancel()
        deadlineSource.cancel()
    }

    private func handleParentLivenessEvent(_ fileDescriptor: Int32) {
        var byte: UInt8 = 0
        let readCount = Darwin.read(fileDescriptor, &byte, 1)
        if readCount == 0 {
            terminateWorker(status: 125)
        } else if readCount < 0,
                  errno != EINTR,
                  errno != EAGAIN,
                  errno != EWOULDBLOCK {
            terminateWorker(status: 125)
        }
    }

    private func terminateWorker(status: Int32) -> Never {
        try? FileManager.default.removeItem(at: workingDirectory)
        Darwin._exit(status)
    }
}
