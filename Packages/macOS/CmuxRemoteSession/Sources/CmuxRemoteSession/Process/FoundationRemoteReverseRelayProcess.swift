internal import Darwin
internal import Foundation

/// Foundation-backed handle for one dedicated SSH reverse-relay process.
///
/// `Process` and `Pipe` callbacks cross executor boundaries; all mutation is
/// owned by Foundation while the coordinator serializes its handle access.
final class FoundationRemoteReverseRelayProcess:
    RemoteReverseRelayProcess,
    @unchecked Sendable
{
    private let process: Process
    private let stderrPipe: Pipe

    init(process: Process, stderrPipe: Pipe) {
        self.process = process
        self.stderrPipe = stderrPipe
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    /// Drains stderr from launch through EOF before reporting termination.
    func captureTermination(
        _ handler: @escaping @Sendable (String?) -> Void
    ) {
        let stderrDescriptor = stderrPipe.fileHandleForReading.fileDescriptor
        // Blocking pipe drainage is a Foundation/Process bridge. It owns the
        // raw descriptor on a utility thread so SSH can never fill the pipe,
        // and the callback cannot outrun the final stderr bytes.
        DispatchQueue.global(qos: .utility).async { [self] in
            let stderr = Self.readStderrTail(fileDescriptor: stderrDescriptor)
            process.waitUntilExit()
            handler(
                RemoteSessionCoordinator.bestErrorLine(stderr: stderr)
                    ?? "status=\(process.terminationStatus)"
            )
        }
    }

    func terminate() {
        process.terminate()
    }

    private static func readStderrTail(
        fileDescriptor: Int32,
        byteLimit: Int = 8192
    ) -> String {
        let chunkSize = 4096
        var bytes = [UInt8](repeating: 0, count: chunkSize)
        var tail = Data()

        while true {
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, chunkSize)
            }
            if count > 0 {
                tail.append(contentsOf: bytes.prefix(count))
                if tail.count > byteLimit {
                    tail.removeFirst(tail.count - byteLimit)
                }
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
        return String(data: tail, encoding: .utf8) ?? ""
    }
}
