import Darwin
import Dispatch
import Foundation
import os

// DispatchSourceRead has no async-native equivalent. Its event handler owns
// captured data and completion state, while `cancel()` is thread-safe.
final class CommandOutputReader: @unchecked Sendable {
    private let descriptor: Int32
    private let maximumBytes: Int?
    private let completion: @Sendable (CommandOutputCapture) -> Void
    // Delivers DispatchSource events and the explicit process-exit drain signal.
    private let queue: DispatchQueue
    private let source: any DispatchSourceRead
    // A synchronous one-shot flag lets a concurrently executing event handler
    // observe cancellation without waiting for its serial queue to drain.
    private let cancellationRequested = OSAllocatedUnfairLock(initialState: false)
    private var data = Data()
    private var isFinished = false

    init?(
        fileHandle: FileHandle,
        maximumBytes: Int?,
        completion: @escaping @Sendable (CommandOutputCapture) -> Void
    ) {
        let duplicate = Darwin.dup(fileHandle.fileDescriptor)
        try? fileHandle.close()
        guard duplicate >= 0 else { return nil }
        let flags = fcntl(duplicate, F_GETFL)
        guard flags >= 0, fcntl(duplicate, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(duplicate)
            return nil
        }

        descriptor = duplicate
        self.maximumBytes = maximumBytes.map { max(0, $0) }
        self.completion = completion
        queue = DispatchQueue(label: "com.cmuxterm.CmuxProcess.output")
        source = DispatchSource.makeReadSource(
            fileDescriptor: duplicate,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.readAvailableBytes()
        }
        source.setCancelHandler {
            Darwin.close(duplicate)
        }
    }

    func start() {
        source.resume()
    }

    func cancel() {
        cancellationRequested.withLock { $0 = true }
        source.cancel()
    }

    func processDidExit() {
        queue.async { [weak self] in
            self?.readAvailableBytes()
        }
    }

    private func readAvailableBytes() {
        guard !isFinished, !cancellationRequested.withLock({ $0 }) else { return }
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            guard !cancellationRequested.withLock({ $0 }) else { return }
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, chunkSize)
            }
            if bytesRead > 0 {
                if let maximumBytes {
                    let remaining = maximumBytes - data.count
                    guard remaining > 0 else {
                        finish(limitExceeded: true)
                        return
                    }
                    data.append(contentsOf: buffer[0..<min(bytesRead, remaining)])
                    if bytesRead > remaining {
                        finish(limitExceeded: true)
                        return
                    }
                } else {
                    data.append(contentsOf: buffer[0..<bytesRead])
                }
            } else if bytesRead == 0 {
                finish(limitExceeded: false)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish(limitExceeded: false)
                return
            }
        }
    }

    private func finish(limitExceeded: Bool) {
        guard !isFinished else { return }
        isFinished = true
        let capture = CommandOutputCapture(data: data, limitExceeded: limitExceeded)
        source.cancel()
        completion(capture)
    }
}
