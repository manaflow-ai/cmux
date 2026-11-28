import Foundation

/// Terminal input and screen reads by the terminal's public id (`term_…`,
/// resource API v2), for a terminal that has no tab on this session: the
/// terminal a remote-terminal tab of another session shows
/// (plans/cmux-next/data-model.md 1.2b). A tab-less terminal has no raw v12
/// surface to name.
extension DaemonConnection {
    private struct Empty: Decodable, Sendable {}

    public func writeTerminal(_ terminal: ResourceID, text: String) async throws {
        let key = "cmux-next-write-" + UUID().uuidString.lowercased()
        let params: [String: JSONValue] = ["terminal": .string(terminal.rawValue), "text": .string(text)]
        _ = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "terminal.input.write", params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<Empty>.self)
    }

    /// Cmd-K (`terminal.history.clear`): the terminal's own daemon clears the
    /// screen and scrollback and every view follows.
    public func clearTerminalHistory(_ terminal: ResourceID) async throws {
        let key = "cmux-next-clear-" + UUID().uuidString.lowercased()
        let params: [String: JSONValue] = ["terminal": .string(terminal.rawValue)]
        _ = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "terminal.history.clear", params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<Empty>.self)
    }
}
