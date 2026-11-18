import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// `cmux keys` (cmux-tui cli/key_broker.rs), run from the app's bundled `cmux` for Settings > Keys
/// and the answer to an agent's key request. A key's value goes to `put` on stdin only, never in
/// the arguments, a log or an error; Swift can't wipe a `String`, so the copies here and in the
/// stdin `Data` are freed, not zeroed. Each command prints its JSON answer on stdout (`--json`) and,
/// on failure, a JSON error `{code, message}` on stderr; both are read defensively, since the
/// answer may come bare or inside an `{ok, result}` envelope.
nonisolated struct KeysCLI: Sendable {
    /// What a failed command said, for the person (never a value: the CLI never prints one).
    nonisolated struct Failure: Error, Sendable, Equatable {
        var code: String
        var message: String
    }

    /// One `cmux keys put` for a request the person answered.
    nonisolated struct Put: Sendable, Equatable {
        var name: String
        var purpose: String?
        var hosts: [String]
        var ttl: String?
        var askedBy: String?
    }

    /// What one run printed and how it exited.
    nonisolated struct Output: Sendable, Equatable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    let binary: URL
    var timeout: Duration = .seconds(60)
    /// Runs the CLI (tests pass a fake): arguments and stdin in, `(status, stdout, stderr)` out.
    var run: @Sendable (_ binary: URL, _ arguments: [String], _ stdin: Data?, _ timeout: Duration) async throws -> Output = { binary, arguments, stdin, timeout in
        let result = try await ProcessRunner.run(executable: binary, arguments: arguments, environment: nil, stdin: stdin, timeout: timeout,
                                                 outputTailBytes: 4 * 1024 * 1024, clock: ContinuousClock())
        return Output(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }

    /// `cmux keys ls --json`: `{version, providers, keys}`.
    func list() async throws -> CmuxNextSettings.JSONValue {
        try await call(["keys", "ls", "--json"])
    }

    /// `cmux keys put NAME … --from-person --replace --json`, the value on stdin: the stored record's answer.
    func put(_ put: Put, value: String) async throws -> CmuxNextSettings.JSONValue {
        guard Self.validName(put.name) else { throw Failure(code: "keys.bad_name", message: "not a key name: \(put.name)") }
        var arguments = ["keys", "put", put.name]
        if let purpose = put.purpose, !purpose.isEmpty { arguments += ["--purpose", purpose] }
        if !put.hosts.isEmpty { arguments += ["--hosts", put.hosts.joined(separator: ",")] }
        if let ttl = put.ttl, !ttl.isEmpty { arguments += ["--ttl", ttl] }
        // The person typed it for this request: it replaces an older value of the same name.
        arguments += ["--replace", "--from-person"]
        if let askedBy = put.askedBy, !askedBy.isEmpty { arguments += ["--asked-by", askedBy] }
        arguments.append("--json")
        return try await call(arguments, stdin: Data(value.utf8))
    }

    /// `cmux keys revoke ID --json`.
    func revoke(id: String) async throws -> CmuxNextSettings.JSONValue {
        guard !id.isEmpty, !id.hasPrefix("-") else { throw Failure(code: "keys.bad_id", message: "not a key id: \(id)") }
        return try await call(["keys", "revoke", id, "--json"])
    }

    private func call(_ arguments: [String], stdin: Data? = nil) async throws -> CmuxNextSettings.JSONValue {
        let result = try await run(binary, arguments, stdin, timeout)
        let object = try Self.answer(status: result.status, stdout: result.stdout, stderr: result.stderr)
        return CmuxNextSettings.JSONValue(foundation: object) ?? .object([:])
    }

    /// The command's answer: the last JSON object on stdout, unwrapped from an `{ok, result}`
    /// envelope when it has one; a failure from the exit status, an `ok: false` envelope or the
    /// JSON error on stderr.
    static func answer(status: Int32, stdout: Data, stderr: Data) throws -> [String: Any] {
        let object = lastObject(stdout)
        if status == 0, let object {
            if let ok = object["ok"] as? Bool {
                guard ok else { throw failure(object["error"] ?? object, status: status) }
                return object["result"] as? [String: Any] ?? [:]
            }
            return object
        }
        throw failure(lastObject(stderr) ?? object ?? [:], status: status)
    }

    /// A key name as the CLI takes it: `[A-Z_][A-Z0-9_]*`, at most 80 characters.
    static func validName(_ name: String) -> Bool {
        guard let first = name.utf8.first, name.utf8.count <= 80, first == 95 || (65...90).contains(first) else { return false }
        return name.utf8.allSatisfy { $0 == 95 || (65...90).contains($0) || (48...57).contains($0) }
    }

    private static func lastObject(_ data: Data) -> [String: Any]? {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        for line in lines where !line.allSatisfy(\.isWhitespace) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { return object }
        }
        return nil
    }

    private static func failure(_ value: Any, status: Int32) -> Failure {
        let object = value as? [String: Any] ?? [:]
        let nested = object["error"] as? [String: Any]
        let code = (nested?["code"] ?? object["code"] ?? object["error_code"]) as? String ?? "keys.failed"
        let message = (nested?["message"] ?? object["message"] ?? object["error"]) as? String ?? "cmux keys exited \(status)"
        return Failure(code: code, message: message.hasPrefix("cmux: ") ? String(message.dropFirst(6)) : message)
    }
}
