import CCmuxLayoutReducerFFI
import Foundation
import os

/// Workspace naming's rules, asked of Rust (cmux-tui/crates/cmux-workspace-naming, with their tests)
/// over the app FFI's JSON channel (`cmux_layout_reducer_json`, ops `workspace_naming_*`). This
/// module reads the facts (its models, the settings, the turn store), asks here and applies the
/// answer; the localized text, observation, timers and async stay in Swift. The rules stay in
/// Rust (Leo, 2026-11-06: "ok we need to go all hands on deck here. don't just do baby steps. we
/// can just... do it").
nonisolated struct WorkspaceNamingRules: Sendable {
    init() {}

    /// One JSON call; nil when it does not answer (a pinned FFI without the op).
    func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(request), let reply = callData("workspace_naming_" + operation, data),
              let decoded = try? JSONDecoder().decode(Reply.self, from: reply) else {
            Self.log.fault("workspace naming rule \(operation, privacy: .public) did not answer")
            return nil
        }
        return decoded
    }

    /// A reply's one optional string field (`{name}`, `{label}`, `{title}`, `{snippet}`).
    func string<Request: Encodable>(_ operation: String, _ request: Request, key: String) -> String? {
        call(operation, request, as: [String: String?].self)?[key] ?? nil
    }

    /// A reply's one boolean field.
    func flag<Request: Encodable>(_ operation: String, _ request: Request, key: String) -> Bool {
        call(operation, request, as: [String: Bool].self)?[key] ?? false
    }

    /// A call whose reply carries nothing.
    func send<Request: Encodable>(_ operation: String, _ request: Request) {
        _ = call(operation, request, as: Empty.self)
    }

    nonisolated struct Empty: Codable {}

    /// A key for a hold or a namer ledger, which Rust keeps until its `_drop`: random, so no
    /// counter is shared (two of 2^64 meet with no practical chance).
    func nextID() -> UInt64 { UInt64.random(in: 1...UInt64.max) }

    private func callData(_ operation: String, _ data: Data) -> Data? {
        var capacity = 4096
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity); var outputLength = 0
            let code: Int32 = data.withUnsafeBytes { requestBytes in operation.withCString { operationCString in output.withUnsafeMutableBytes { outputBytes in cmux_layout_reducer_json(requestBytes.bindMemory(to: UInt8.self).baseAddress, data.count, operationCString, outputBytes.bindMemory(to: UInt8.self).baseAddress, outputBytes.count, &outputLength) } } }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, outputLength > capacity {
                capacity = outputLength
                continue
            }
            guard code == CMUX_LAYOUT_REDUCER_OK, outputLength <= capacity else { return nil }
            return Data(output.prefix(outputLength))
        }
        return nil
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "workspace-naming")
}
