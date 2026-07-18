import Darwin
import Foundation

struct AgentStagedOutput {
    private let readChunkBytes: Int

    init(readChunkBytes: Int = 64 * 1_024) {
        precondition(readChunkBytes > 0)
        self.readChunkBytes = readChunkBytes
    }

    func publish(
        build: (FileHandle) throws -> Void,
        publishChunk: (Data) -> Void
    ) throws {
        let templatePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agents-output.XXXXXX", isDirectory: false)
            .path
        var template = templatePath.utf8CString
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress)
        }
        guard descriptor >= 0 else { throw posixError() }
        let path = String(
            decoding: template.dropLast().map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let error = posixError()
            Darwin.close(descriptor)
            path.withCString { _ = Darwin.unlink($0) }
            throw error
        }
        guard path.withCString({ Darwin.unlink($0) }) == 0 else {
            let error = posixError()
            Darwin.close(descriptor)
            throw error
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
        }

        // Build the complete document before publishing its first byte. Store
        // validation or row-encoding failures therefore cannot leave a partial
        // JSON object on stdout.
        try build(handle)
        try handle.seek(toOffset: 0)
        while let chunk = try handle.read(upToCount: readChunkBytes), !chunk.isEmpty {
            publishChunk(chunk)
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
