import Darwin
import Dispatch
import Foundation

// DispatchSourceWrite has no async-native equivalent. Its event handler owns
// all offset mutation, while `cancel()` is the source's thread-safe lifecycle API.
final class CommandStandardInputWriter: @unchecked Sendable {
    private var data: Data?
    private let descriptor: Int32
    private let source: any DispatchSourceWrite
    private var offset = 0

    init?(fileHandle: FileHandle, data: Data) {
        let duplicate = Darwin.dup(fileHandle.fileDescriptor)
        try? fileHandle.close()
        guard duplicate >= 0 else { return nil }
        guard fcntl(duplicate, F_SETNOSIGPIPE, 1) == 0 else {
            Darwin.close(duplicate)
            return nil
        }
        let flags = fcntl(duplicate, F_GETFL)
        guard flags >= 0, fcntl(duplicate, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(duplicate)
            return nil
        }

        self.data = data
        descriptor = duplicate
        source = DispatchSource.makeWriteSource(
            fileDescriptor: duplicate,
            queue: DispatchQueue(label: "com.cmuxterm.CmuxProcess.stdin")
        )
        source.setEventHandler { [weak self] in
            self?.writeAvailableBytes()
        }
        source.setCancelHandler { [weak self] in
            self?.data = nil
            Darwin.close(duplicate)
        }
        source.resume()
        if data.isEmpty {
            source.cancel()
        }
    }

    func cancel() {
        source.cancel()
    }

    private func writeAvailableBytes() {
        guard !source.isCancelled, let data else { return }
        let available = max(1, Int(source.data))
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress, offset < bytes.count else { return 0 }
            return Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                min(available, bytes.count - offset)
            )
        }
        if written > 0 {
            offset += written
            if offset == data.count {
                source.cancel()
            }
        } else if written == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            source.cancel()
        }
    }
}
