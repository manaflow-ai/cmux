import Darwin
import Foundation

extension CuaDriverManager {
    func performHandshake(
        input: FileHandle,
        lines: CuaDriverLineInbox,
        pid: Int32
    ) async throws -> RunningInfo {
        try writeJSONObject([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": [
                    "name": "cmux",
                    "version": "dev",
                ],
            ],
        ], to: input)

        let initialize = try await response(id: 1, lines: lines)
        guard initialize.keys.contains("result") else {
            throw CuaDriverManagerError.invalidInitializeResponse
        }
        let serverInfo = (initialize["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        let serverName = serverInfo?["name"] as? String
        let serverVersion = serverInfo?["version"] as? String

        try writeJSONObject([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ], to: input)

        try writeJSONObject([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ], to: input)

        let toolsList = try await response(id: 2, lines: lines)
        guard
            let result = toolsList["result"] as? [String: Any],
            let tools = result["tools"] as? [Any]
        else {
            throw CuaDriverManagerError.invalidToolsListResponse
        }

        return RunningInfo(
            pid: pid,
            serverName: serverName,
            serverVersion: serverVersion,
            toolCount: tools.count
        )
    }

    private func response(id: Int, lines: CuaDriverLineInbox) async throws -> [String: Any] {
        try await withTimeout(.seconds(10)) {
            while true {
                guard let line = try await lines.nextLine() else {
                    throw CuaDriverManagerError.unexpectedEOF
                }
                let message = try Self.decodeJSONObject(line)
                if let responseID = message["id"] as? Int, responseID == id {
                    return message
                }
            }
        }
    }

    private func writeJSONObject(_ object: [String: Any], to input: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = Data(data)
        line.append(0x0A)
        try input.write(contentsOf: line)
    }

    nonisolated private static func decodeJSONObject(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw CuaDriverManagerError.invalidUTF8
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CuaDriverManagerError.invalidJSON
        }
        return object
    }
}

enum CuaDriverManagerError: LocalizedError {
    case timeout
    case unexpectedEOF
    case invalidUTF8
    case invalidJSON
    case invalidInitializeResponse
    case invalidToolsListResponse

    var errorDescription: String? {
        switch self {
        case .timeout:
            return String(localized: "settings.computerUse.driver.error.timeout", defaultValue: "Timed out waiting for cua-driver.")
        case .unexpectedEOF:
            return String(localized: "settings.computerUse.driver.error.eof", defaultValue: "cua-driver closed stdout before the handshake completed.")
        case .invalidUTF8:
            return String(localized: "settings.computerUse.driver.error.utf8", defaultValue: "cua-driver returned non-UTF-8 output.")
        case .invalidJSON:
            return String(localized: "settings.computerUse.driver.error.json", defaultValue: "cua-driver returned invalid JSON.")
        case .invalidInitializeResponse:
            return String(localized: "settings.computerUse.driver.error.initialize", defaultValue: "cua-driver returned an invalid initialize response.")
        case .invalidToolsListResponse:
            return String(localized: "settings.computerUse.driver.error.tools", defaultValue: "cua-driver returned an invalid tools/list response.")
        }
    }
}

// Stdout has exactly one consumer at a time: handshake first, then lifetime drain.
final class CuaDriverLineInbox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<String, Error>.Iterator

    init(stream: AsyncThrowingStream<String, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func nextLine() async throws -> String? {
        try await iterator.next()
    }
}

enum CuaDriverLineStream {
    static func lines(from fileHandle: FileHandle) -> AsyncThrowingStream<String, Error> {
        let fd = dup(fileHandle.fileDescriptor)
        return AsyncThrowingStream { continuation in
            guard fd >= 0 else {
                continuation.finish(throwing: POSIXError(.EBADF))
                return
            }
            let task = Task.detached(priority: .utility) {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var buffer = Data()
                do {
                    while !Task.isCancelled {
                        let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                        if chunk.isEmpty {
                            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                                continuation.yield(line)
                            }
                            continuation.finish()
                            return
                        }
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[..<newline]
                            let next = buffer.index(after: newline)
                            buffer.removeSubrange(..<next)
                            if let line = String(data: lineData, encoding: .utf8) {
                                continuation.yield(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                            } else {
                                continuation.finish(throwing: CuaDriverManagerError.invalidUTF8)
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func drain(fileHandle: FileHandle) -> Task<Void, Never> {
        let fd = dup(fileHandle.fileDescriptor)
        return Task.detached(priority: .utility) {
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            while !Task.isCancelled {
                do {
                    let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                    if chunk.isEmpty { return }
                } catch {
                    return
                }
            }
        }
    }

    static func drain(lines: CuaDriverLineInbox) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do {
                while !Task.isCancelled {
                    guard try await lines.nextLine() != nil else { return }
                }
            } catch {
                return
            }
        }
    }
}
