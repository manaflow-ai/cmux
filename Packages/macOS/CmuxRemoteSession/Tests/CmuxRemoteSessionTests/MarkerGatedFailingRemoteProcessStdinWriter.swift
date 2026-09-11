import Darwin
import Foundation
@testable import CmuxRemoteSession

struct MarkerGatedFailingRemoteProcessStdinWriter: RemoteProcessStdinWriting {
    let readyFIFOURL: URL
    let exitFIFOURL: URL
    let markerURL: URL
    let gate: RemoteProcessStdinWriterFailureGate

    func write(
        _ data: Data,
        to handle: FileHandle,
        stopFileDescriptor: Int32
    ) throws {
        let processIdentifier = try readProcessIdentifier()
        try Data("\(processIdentifier)".utf8).write(to: markerURL)
        if gate == .exited {
            let exitHandle = try FileHandle(forReadingFrom: exitFIFOURL)
            defer { try? exitHandle.close() }
            _ = exitHandle.readDataToEndOfFile()
        }
        throw POSIXError(.EIO)
    }

    private func readProcessIdentifier() throws -> pid_t {
        let readyHandle = try FileHandle(forReadingFrom: readyFIFOURL)
        defer { try? readyHandle.close() }
        let contents = String(
            decoding: readyHandle.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard let processIdentifier = pid_t(
            contents.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw POSIXError(.EINVAL)
        }
        return processIdentifier
    }
}
