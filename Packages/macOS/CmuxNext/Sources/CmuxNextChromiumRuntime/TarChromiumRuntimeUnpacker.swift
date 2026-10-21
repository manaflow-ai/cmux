public import Foundation
import Darwin

/// Lists and extracts a pack with the system `tar` (bsdtar: it reads xz and
/// refuses absolute paths and `..` by itself; the installer checks again).
public struct TarChromiumRuntimeUnpacker: ChromiumRuntimeUnpacking {
    /// The tar executable.
    public var tool: URL

    /// Creates an unpacker.
    ///
    /// - Parameter tool: The tar to run; `/usr/bin/tar` by default.
    public init(tool: URL = URL(filePath: "/usr/bin/tar")) {
        self.tool = tool
    }

    public func entries(of archive: URL) async throws(ChromiumRuntimeInstallError) -> [String] {
        let output = try await run(["-tf", archive.path])
        return output.split(separator: "\n").map(String.init)
    }

    public func unpack(_ archive: URL, into directory: URL) async throws(ChromiumRuntimeInstallError) {
        _ = try await run(["-xf", archive.path, "-C", directory.path, "--no-same-owner"])
    }

    private func run(_ arguments: [String]) async throws(ChromiumRuntimeInstallError) -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        // Drain the pipe beside the process, keyed by the raw descriptor, so a
        // long listing cannot fill the pipe and stall tar.
        let reader = Task.detached { readAll(descriptor) }
        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            try? pipe.fileHandleForWriting.close()
            reader.cancel()
            throw .unpack(error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()
        let output = String(decoding: await reader.value, as: UTF8.self)
        guard status == 0 else { throw .unpack(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }
}

/// Reads `descriptor` to its end (a blocking read on a detached task).
private func readAll(_ descriptor: Int32) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    // wakeup-allow: a blocking read on a detached task; it ends at EOF (0) or on a read error.
    while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 { data.append(contentsOf: buffer[0..<count]); continue }
        if count < 0, errno == EINTR { continue }
        return data
    }
}
