import Foundation
import CmuxNextDaemon
import os

/// The small, backend-neutral bridge used by the cmux ACPmux surface.
///
/// ACPmux intentionally stays behind this seam. The window and the phone
/// speak in terms of sessions, history, and prompts, while this service owns
/// discovery of the bundled executable and the process boundary. Keeping the
/// boundary here means another agent backend can be added without changing
/// either UI.
actor AcpmuxAgentService {
    enum ServiceError: LocalizedError, Sendable {
        case executableMissing
        case commandFailed(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .executableMissing:
                "The ACPmux executable is not bundled with this build."
            case .commandFailed(let message): message
            case .invalidResponse:
                "ACPmux returned an invalid response."
            }
        }
    }

    struct Session: Sendable, Identifiable, Hashable {
        let id: String
        let name: String
        let harness: String
        let status: String
        let lastPrompt: String

        init(id: String, name: String, harness: String, status: String, lastPrompt: String) {
            self.id = id
            self.name = name
            self.harness = harness
            self.status = status
            self.lastPrompt = lastPrompt
        }

        init?(json: JSONValue) {
            guard case .object(let object) = json,
                  let id = object["sessionId"]?.stringValue,
                  !id.isEmpty else { return nil }
            self.id = id
            self.name = object["name"]?.stringValue ?? id
            self.harness = object["harness"]?.stringValue ?? "agent"
            self.status = object["status"]?.stringValue ?? "unknown"
            self.lastPrompt = object["lastPrompt"]?.stringValue ?? ""
        }
    }

    struct Turn: Sendable, Hashable, Identifiable {
        let id: String
        let role: String
        let text: String

        init?(json: JSONValue, index: Int) {
            guard case .object(let object) = json else { return nil }
            let role = object["role"]?.stringValue ?? object["kind"]?.stringValue ?? "event"
            let text = object["text"]?.stringValue
                ?? object["content"]?.stringValue
                ?? object["reply"]?.stringValue
                ?? object["prompt"]?.stringValue
                ?? ""
            guard !text.isEmpty else { return nil }
            self.id = "\(index)-\(role)-\(text.hashValue)"
            self.role = role
            self.text = text
        }
    }

    private let executable: URL?
    private let home: URL
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "acpmux")

    init(executable: URL? = nil) {
        if let executable {
            self.executable = executable
        } else if let override = ProcessInfo.processInfo.environment["CMUX_ACPMUX_BIN"],
                  !override.isEmpty {
            self.executable = URL(fileURLWithPath: override)
        } else if let bundled = Bundle.main.url(forResource: "acpmux", withExtension: nil,
                                                subdirectory: "bin") {
            self.executable = bundled
        } else {
            let candidates = [
                "/opt/homebrew/bin/acpmux",
                "/usr/local/bin/acpmux",
                NSHomeDirectory() + "/.cargo/bin/acpmux",
            ]
            self.executable = candidates.lazy.map(URL.init(fileURLWithPath:)).first {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.home = support.appendingPathComponent("cmux/acpmux", isDirectory: true)
    }

    func listSessions() throws -> [Session] {
        let value = try run(["--json", "ls"])
        guard case .object(let object) = value,
              let rows = object["sessions"]?.arrayValue else { return [] }
        return rows.compactMap(Session.init(json:))
    }

    func createSession(name: String? = nil, model: String? = nil, cwd: String? = nil) throws -> Session {
        var args = ["--json", "new"]
        if let name, !name.isEmpty { args += ["--name", name] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let cwd, !cwd.isEmpty { args += ["--cwd", cwd] }
        let value = try run(args)
        if let session = Session(json: value) { return session }
        if case .object(let object) = value,
           let id = object["sessionId"]?.stringValue {
            return Session(id: id, name: object["name"]?.stringValue ?? id,
                           harness: object["harness"]?.stringValue ?? "agent",
                           status: object["status"]?.stringValue ?? "ready", lastPrompt: "")
        }
        throw ServiceError.invalidResponse
    }

    func history(sessionID: String, limit: Int = 200) throws -> [Turn] {
        let value = try run(["--json", "history", sessionID, "--limit", String(max(1, limit))])
        let rows: [JSONValue]
        if case .object(let object) = value, let turns = object["turns"]?.arrayValue {
            rows = turns
        } else if case .array(let values) = value {
            rows = values
        } else {
            rows = []
        }
        return rows.enumerated().compactMap { Turn(json: $0.element, index: $0.offset) }
    }

    func send(sessionID: String, prompt: String) throws -> String {
        let value = try run(["--json", "send", sessionID, prompt])
        if let reply = value["reply"]?.stringValue { return reply }
        if let text = value["text"]?.stringValue { return text }
        if case .string(let text) = value { return text }
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func cancel(sessionID: String) throws {
        _ = try run(["--json", "session", "cancel", sessionID])
    }

    /// Entry point used by the authenticated phone RPC adapter. It mirrors
    /// the same narrow vocabulary as the Mac window and never exposes admin
    /// ACPmux methods to a phone.
    func mobileRequest(method: String, params: [String: JSONValue]) throws -> JSONValue {
        switch method {
        case "sessions":
            let rows = try listSessions()
            return .object(["sessions": .array(rows.map { .object([
                "sessionId": .string($0.id), "name": .string($0.name),
                "harness": .string($0.harness), "status": .string($0.status),
                "lastPrompt": .string($0.lastPrompt),
            ]) })])
        case "new":
            let session = try createSession(name: params["name"]?.stringValue,
                                             model: params["model"]?.stringValue,
                                             cwd: params["cwd"]?.stringValue)
            return .object(["sessionId": .string(session.id), "name": .string(session.name),
                            "harness": .string(session.harness), "status": .string(session.status)])
        case "history":
            guard let id = params["sessionId"]?.stringValue else { throw ServiceError.commandFailed("sessionId is required") }
            let turns = try history(sessionID: id, limit: Int(params["limit"]?.doubleValue ?? 200))
            return .object(["sessionId": .string(id), "turns": .array(turns.map {
                .object(["id": .string($0.id), "role": .string($0.role), "text": .string($0.text)])
            })])
        case "send":
            guard let id = params["sessionId"]?.stringValue,
                  let prompt = params["prompt"]?.stringValue else {
                throw ServiceError.commandFailed("sessionId and prompt are required")
            }
            return .object(["sessionId": .string(id), "reply": .string(try send(sessionID: id, prompt: prompt))])
        case "cancel":
            guard let id = params["sessionId"]?.stringValue else { throw ServiceError.commandFailed("sessionId is required") }
            try cancel(sessionID: id)
            return .object(["sessionId": .string(id), "cancelled": .bool(true)])
        default:
            throw ServiceError.commandFailed("unsupported ACPmux operation")
        }
    }

    private func run(_ arguments: [String]) throws -> JSONValue {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ServiceError.executableMissing
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ACPMUX_HOME"] = home.path
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ServiceError.commandFailed("could not launch ACPmux: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "ACPmux exited with status \(process.terminationStatus)"
            logger.error("command failed: \(message, privacy: .public)")
            throw ServiceError.commandFailed(message)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let decoder = JSONDecoder()
        if let json = try? decoder.decode(JSONValue.self, from: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) {
            return json
        }
        // ACPmux's JSON mode pretty-prints responses. Keep the fallback
        // tolerant of diagnostics before the response while still selecting
        // the final complete JSON value.
        var parsed: JSONValue?
        var offset = text.startIndex
        while offset < text.endIndex {
            if text[offset] == "{" || text[offset] == "[" {
                let candidate = String(text[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = try? decoder.decode(JSONValue.self, from: Data(candidate.utf8)) {
                    parsed = value
                }
            }
            offset = text.index(after: offset)
        }
        guard let json = parsed else {
            throw ServiceError.invalidResponse
        }
        return json
    }
}
