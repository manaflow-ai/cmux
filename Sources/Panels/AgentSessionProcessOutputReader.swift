import Darwin
import Foundation

/// Streams bounded chunks from a live process without waiting to fill a buffer.
struct AgentSessionProcessOutputReader {
    let fileHandle: FileHandle

    func start(onData: @escaping @Sendable (Data) async -> Void) -> Task<Void, Never> {
        let descriptor = fileHandle.fileDescriptor
        return Task.detached(priority: .utility) { [fileHandle] in
            // Keep this handle alive until its reader finishes; the descriptor
            // must not be closed and reused while a read is in progress.
            defer { withExtendedLifetime(fileHandle) {} }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !Task.isCancelled {
                // FileHandle.read(upToCount:) fills the requested buffer before
                // returning on macOS. A JSONL peer waits for our next request,
                // so read the available bytes with one syscall instead.
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0 && errno == EINTR { continue }
                let data = count > 0 ? Data(buffer.prefix(count)) : Data()
                await onData(data)
                if data.isEmpty { return }
            }
        }
    }
}
