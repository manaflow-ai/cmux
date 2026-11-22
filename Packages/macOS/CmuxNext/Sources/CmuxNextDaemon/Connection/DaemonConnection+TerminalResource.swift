import Foundation

/// Terminal input and screen reads by the terminal's public id (`term_…`,
/// resource API v2), for a terminal that has no tab on this session: the
/// terminal a remote-terminal tab of another session shows
/// (plans/cmux-next/data-model.md 1.2b). A tab-less terminal has no raw v12
/// surface to name.
extension DaemonConnection {
    private struct Empty: Decodable, Sendable {}

    /// The visible screen text.
    public struct TerminalScreen: Decodable, Sendable {
        public var text: String
        public var cols: Int
        public var rows: Int
    }

    public func writeTerminal(_ terminal: ResourceID, text: String) async throws {
        let key = "cmux-next-write-" + UUID().uuidString.lowercased()
        let params: [String: JSONValue] = ["terminal": .string(terminal.rawValue), "text": .string(text)]
        _ = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "terminal.input.write", params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<Empty>.self)
    }

    /// Key chords in `send-key` syntax (`enter`, `ctrl+c`).
    public func sendTerminalKeys(_ terminal: ResourceID, keys: [String]) async throws {
        let key = "cmux-next-keys-" + UUID().uuidString.lowercased()
        let params: [String: JSONValue] = ["terminal": .string(terminal.rawValue), "keys": .array(keys.map(JSONValue.string))]
        _ = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "terminal.input.keys", params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<Empty>.self)
    }

    public func readTerminalScreen(_ terminal: ResourceID) async throws -> TerminalScreen {
        let params: [String: JSONValue] = ["terminal": .string(terminal.rawValue)]
        return try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "terminal.screen.read", params: params, idempotencyKey: nil)
        }, as: TerminalScreen.self)
    }
}
