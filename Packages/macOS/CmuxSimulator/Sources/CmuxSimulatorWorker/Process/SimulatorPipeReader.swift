import Darwin
import Foundation

/// Drains a subprocess pipe on a dedicated thread so compiler diagnostics
/// cannot fill the kernel pipe buffer and deadlock the isolated worker.
actor SimulatorPipeReader {
    typealias Result = (data: Data, truncated: Bool)

    private let fileDescriptor: Int32
    private let stopSignal: Pipe
    private let name: String
    private let limit: Int
    private var result: Result?
    private var waiters: [CheckedContinuation<Result, Never>] = []
    private var started = false

    init(handle: FileHandle, name: String, limit: Int) {
        fileDescriptor = handle.fileDescriptor
        stopSignal = Pipe()
        let stopDescriptor = stopSignal.fileHandleForWriting.fileDescriptor
        let flags = fcntl(stopDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(stopDescriptor, F_SETFL, flags | O_NONBLOCK) }
        self.name = name
        self.limit = limit
    }

    func start() {
        guard !started else { return }
        started = true
        let fileDescriptor = self.fileDescriptor
        let stopFileDescriptor = stopSignal.fileHandleForReading.fileDescriptor
        let limit = self.limit
        let thread = Thread { [weak self] in
            let result = readSimulatorPipeToEnd(
                fileDescriptor: fileDescriptor,
                limit: limit,
                stopFileDescriptor: stopFileDescriptor
            )
            Task { await self?.finish(result) }
        }
        thread.name = name
        thread.stackSize = 1 << 20
        thread.start()
    }

    func requestStop() {
        var byte: UInt8 = 1
        _ = Darwin.write(stopSignal.fileHandleForWriting.fileDescriptor, &byte, 1)
    }

    func waitForEnd() async -> Result {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func finish(_ result: Result) {
        guard self.result == nil else { return }
        self.result = result
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }
}

private func readSimulatorPipeToEnd(
    fileDescriptor: Int32,
    limit: Int,
    stopFileDescriptor: Int32
) -> (data: Data, truncated: Bool) {
    let flags = fcntl(fileDescriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    var data = Data()
    data.reserveCapacity(limit)
    var truncated = false
    var stopRequested = false
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let bufferCount = buffer.count
        let count = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return Darwin.read(fileDescriptor, baseAddress, bufferCount)
        }
        if count > 0 {
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
            }
            if count > remaining { truncated = true }
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            if stopRequested { break }
            var descriptors = [
                pollfd(fd: fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: stopFileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0),
            ]
            _ = Darwin.poll(&descriptors, 2, 100)
            if descriptors[1].revents != 0 {
                // The process-exit callback can race buffered pipe data. Make one
                // more nonblocking drain pass before honoring the bounded stop.
                stopRequested = true
            }
        } else {
            break
        }
    }
    return (data, truncated)
}
