import CmuxConversation
import Foundation

/// Uploads one file to acpmux over its own stream: a JSON handshake, the
/// raw bytes from the offset acpmux already has, then acpmux's verdict.
struct AcpmuxUploader {
    let opener: any ConversationStreamOpening
    static let chunk = 256 * 1024

    func upload(_ file: UploadFile, sessionID: String) -> AsyncThrowingStream<UInt64, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(file, sessionID: sessionID, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func line(_ v: JSONValue) throws -> Data {
        var d = try JSONEncoder().encode(v)
        d.append(0x0A)
        return d
    }

    private func run(_ file: UploadFile, sessionID: String, _ out: AsyncThrowingStream<UInt64, any Error>.Continuation) async throws {
        let stream = try await opener.open(.transfer)
        defer { Task { await stream.close() } }
        var reader = LineReader()
        let hello: JSONValue = .object(["upload": .object([
            "sessionId": .string(sessionID), "uploadId": .string(file.uploadID), "name": .string(file.name),
            "mimeType": .string(file.mimeType), "size": .number(Double(file.size)), "sha256": .string(file.sha256),
        ])])
        try await stream.write(line(hello))
        guard let first = try await reader.next(from: stream) else { throw ConversationBackendError.unreachable("upload closed early") }
        let reply = try JSONDecoder().decode(JSONValue.self, from: first)
        if let error = reply["error"]?.stringValue { throw ConversationBackendError.refused(code: 0, message: error) }
        guard var sent = reply["received"]?.uint64Value else { throw ConversationBackendError.protocolViolation("upload handshake") }
        out.yield(sent)
        if sent < file.size {
            let handle = try FileHandle(forReadingFrom: file.fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: sent)
            while sent < file.size {
                try Task.checkCancellation()
                let want = Int(min(UInt64(Self.chunk), file.size - sent))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else {
                    throw ConversationBackendError.protocolViolation("\(file.name) is shorter than declared")
                }
                try await stream.write(data)
                sent += UInt64(data.count)
                out.yield(sent)
            }
        }
        guard let last = try await reader.next(from: stream) else { throw ConversationBackendError.unreachable("upload closed before acpmux confirmed it") }
        let verdict = try JSONDecoder().decode(JSONValue.self, from: last)
        if let error = verdict["error"]?.stringValue { throw ConversationBackendError.refused(code: 0, message: error) }
        guard verdict["done"]?.boolValue == true else { throw ConversationBackendError.protocolViolation("upload verdict") }
        out.yield(file.size)
    }
}
