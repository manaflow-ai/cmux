import Darwin
import Foundation

/// Drains one probe process output pipe off Swift's cooperative executor.
/// The actor owns descriptor close state, while the blocking `poll/read`
/// loop runs on a GCD queue so the actor remains available for cancellation.
actor AgentForkCommandOutputDrain {
    private static let queue = DispatchQueue(
        label: "com.cmux.agent-fork-support.output-drain",
        qos: .utility,
        attributes: .concurrent
    )
    private let readFileDescriptor: Int32
    private let wakeReadFileDescriptor: Int32
    private let wakeWriteFileDescriptor: Int32
    private let maximumBytes: Int
    private var didCloseFileDescriptors = false

    init?(readFileDescriptor: Int32, maximumBytes: Int) {
        var wakeFDs: [Int32] = [-1, -1]
        guard Darwin.pipe(&wakeFDs) == 0 else { return nil }
        guard wakeFDs.allSatisfy({ $0 > 2 }) else {
            for fileDescriptor in wakeFDs where fileDescriptor >= 0 {
                close(fileDescriptor)
            }
            return nil
        }
        for fileDescriptor in wakeFDs {
            _ = fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        self.readFileDescriptor = readFileDescriptor
        self.wakeReadFileDescriptor = wakeFDs[0]
        self.wakeWriteFileDescriptor = wakeFDs[1]
        self.maximumBytes = maximumBytes
    }

    func run() async -> Data {
        let readFileDescriptor = self.readFileDescriptor
        let wakeReadFileDescriptor = self.wakeReadFileDescriptor
        let maximumBytes = self.maximumBytes
        let output = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(
                    returning: Self.drainOutput(
                        readFileDescriptor: readFileDescriptor,
                        wakeReadFileDescriptor: wakeReadFileDescriptor,
                        maximumBytes: maximumBytes
                    )
                )
            }
        }
        closeFileDescriptors()
        return output
    }

    nonisolated func cancel() {
        Task {
            await requestCancel()
        }
    }

    private func requestCancel() {
        guard !didCloseFileDescriptors else { return }
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) { pointer in
            Darwin.write(wakeWriteFileDescriptor, pointer, 1)
        }
    }

    private static func drainOutput(
        readFileDescriptor: Int32,
        wakeReadFileDescriptor: Int32,
        maximumBytes: Int
    ) -> Data {
        var output = Data()
        var pollDescriptors = [
            pollfd(
                fd: readFileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            ),
            pollfd(
                fd: wakeReadFileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            ),
        ]
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let pollResult = Darwin.poll(&pollDescriptors, 2, -1)
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                output.removeAll(keepingCapacity: false)
                break
            }
            if pollDescriptors[1].revents != 0 {
                break
            }
            if pollDescriptors[0].revents & Int16(POLLIN | POLLHUP | POLLERR) == 0 {
                continue
            }
            let bufferCapacity = buffer.count
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(readFileDescriptor, rawBuffer.baseAddress, bufferCapacity)
            }
            if bytesRead > 0 {
                let remaining = maximumBytes - output.count
                if remaining > 0 {
                    output.append(contentsOf: buffer.prefix(min(Int(bytesRead), remaining)))
                }
            } else if bytesRead == 0 {
                break
            } else if errno != EINTR {
                output.removeAll(keepingCapacity: false)
                break
            }
        }
        return output
    }

    private func closeFileDescriptors() {
        guard !didCloseFileDescriptors else { return }
        didCloseFileDescriptors = true
        close(readFileDescriptor)
        close(wakeReadFileDescriptor)
        close(wakeWriteFileDescriptor)
    }

    deinit {
        if !didCloseFileDescriptors {
            close(readFileDescriptor)
            close(wakeReadFileDescriptor)
            close(wakeWriteFileDescriptor)
        }
    }
}
