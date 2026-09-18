import Foundation

/// Immutable wire request. Application code uses resource operations directly;
/// it never round-trips commands through CLI argument parsing.
struct CloudTuiRequest: Sendable, Equatable {
    let operation: String
    let parameters: Data
    let raw: Bool
    var idempotencyKey: String?

    init(_ operation: String, _ params: [String: Any] = [:], mutation: Bool = false, key: String? = nil, raw: Bool = false) {
        self.operation = operation
        self.raw = raw
        var params = params
        if !raw && operation != "request.cancel" {
            params["machine"] = params["machine"] ?? "current"
            params["session"] = params["session"] ?? "current"
        }
        // Builders below supply only JSON strings, arrays, booleans and integers.
        parameters = try! JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        idempotencyKey = mutation ? key ?? "mutation-\(UUID().uuidString.lowercased())" : nil
    }

    var params: [String: Any] { (try? JSONSerialization.jsonObject(with: parameters)) as? [String: Any] ?? [:] }

    func adding(_ fields: [String: Any]) -> Self {
        Self(operation, params.merging(fields) { _, new in new }, mutation: idempotencyKey != nil, key: idempotencyKey, raw: raw)
    }

    func envelope(id: String) throws -> Data {
        var object: [String: Any]
        if raw {
            object = params.merging(["id": id, "cmd": operation]) { _, new in new }
        } else {
            object = ["protocol": "cmux.protocol/2", "type": "request", "id": id, "operation": operation, "params": params]
            if let idempotencyKey { object["idempotency_key"] = idempotencyKey }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// Builders for the Cloud application's complete control surface.
/// Public IDs are absolute. Never add focused workspace/pane selectors to them.
enum CloudTuiRequests {
    static func snapshotArguments(socketPath: String) -> CloudTuiRequest { CloudTuiRequest("session.snapshot") }
    static func createWorkspaceArguments(socketPath: String, name: String? = nil, empty: Bool = false) -> CloudTuiRequest {
        var fields: [String: Any] = ["initial_content": empty ? "empty" : "terminal"]
        if let name, !name.isEmpty { fields["name"] = name }
        return CloudTuiRequest("workspace.create", fields, mutation: true)
    }
    static func runArguments(socketPath: String, workspaceID: String, command: [String], onExit: String? = nil, cwd: String? = nil, idempotencyKey: String? = nil, correlationKey: String? = nil) -> CloudTuiRequest {
        var fields: [String: Any] = ["workspace": workspaceID, "argv": command]
        if let onExit { fields["on_exit"] = onExit }
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty { fields["cwd"] = cwd }
        if let correlationKey { fields["correlation_key"] = correlationKey }
        return CloudTuiRequest("workspace.run", fields, mutation: true, key: idempotencyKey)
    }
    static func paneCreate(paneID: String, direction: String?, command: [String], revision: UInt64?, key: String, correlationKey: String?) -> CloudTuiRequest {
        var fields: [String: Any] = ["pane": paneID]
        if let direction { fields["direction"] = direction } else { fields["argv"] = command }
        if let revision { fields["expected_revision"] = String(revision) }
        if let correlationKey { fields["correlation_key"] = correlationKey }
        return CloudTuiRequest(direction == nil ? "pane.run" : "pane.split", fields, mutation: true, key: key)
    }
    static func closeTerminalArguments(socketPath: String, terminalID: String) -> CloudTuiRequest { CloudTuiRequest("terminal.close", ["terminal": terminalID], mutation: true) }
    static func closeTabArguments(socketPath: String, tabID: String) -> CloudTuiRequest { CloudTuiRequest("tab.close", ["tab": tabID], mutation: true) }
    static func closeWorkspaceArguments(socketPath: String, workspaceID: String) -> CloudTuiRequest { CloudTuiRequest("workspace.close", ["workspace": workspaceID], mutation: true) }
    static func renameWorkspaceArguments(socketPath: String, workspaceID: String, name: String, expectedRevision: UInt64? = nil) -> CloudTuiRequest {
        rename("workspace.rename", fields: ["workspace": workspaceID, "name": name], revision: expectedRevision)
    }
    static func renameTabArguments(socketPath: String, tabID: String, name: String, expectedRevision: UInt64? = nil) -> CloudTuiRequest {
        rename("tab.rename", fields: ["tab": tabID, "name": name], revision: expectedRevision)
    }
    private static func rename(_ op: String, fields: [String: Any], revision: UInt64?) -> CloudTuiRequest {
        var fields = fields
        if let revision { fields["expected_revision"] = String(revision) }
        return CloudTuiRequest(op, fields, mutation: true)
    }
    static func projectTerminalArguments(socketPath: String, terminalID: String, target: CloudTuiTerminalProjectionTarget, expectedRevision: String? = nil, idempotencyKey: String? = nil) -> CloudTuiRequest {
        placement("terminal.project", source: ["terminal": terminalID], target: target, revision: expectedRevision, key: idempotencyKey)
    }
    static func moveTabArguments(socketPath: String, tabID: String, target: CloudTuiTerminalProjectionTarget, expectedRevision: String? = nil, idempotencyKey: String? = nil) -> CloudTuiRequest {
        placement("tab.move", source: ["tab": tabID], target: target, revision: expectedRevision, key: idempotencyKey)
    }
    private static func placement(_ op: String, source: [String: Any], target: CloudTuiTerminalProjectionTarget, revision: String?, key: String?) -> CloudTuiRequest {
        var fields = source
        fields["destination_workspace"] = target.workspaceID
        fields["destination_screen"] = target.screenID
        fields["destination_pane"] = target.paneID
        fields["index"] = target.index
        if let revision { fields["expected_revision"] = revision }
        return CloudTuiRequest(op, fields, mutation: true, key: key)
    }
    static func notificationAckArguments(socketPath: String, clientID: String, notificationIDs: [String], idempotencyKey: String) -> CloudTuiRequest {
        CloudTuiRequest("notification.ack", ["client_id": clientID, "notifications": notificationIDs], mutation: true, key: idempotencyKey)
    }
    static func keysArguments(socketPath: String, terminalID: String, keys: [String]) -> CloudTuiRequest { CloudTuiRequest("terminal.input.keys", ["terminal": terminalID, "keys": keys], mutation: true) }
    static func writeBytes(terminalID: String, data: Data) -> CloudTuiRequest { CloudTuiRequest("terminal.input.write", ["terminal": terminalID, "bytes_base64": data.base64EncodedString()], mutation: true) }
    static func screenReadArguments(socketPath: String, terminalID: String) -> CloudTuiRequest { CloudTuiRequest("terminal.screen.read", ["terminal": terminalID]) }
    static func processInfoArguments(socketPath: String, terminalID: String) -> CloudTuiRequest { CloudTuiRequest("terminal.process.get", ["terminal": terminalID]) }
    static func screenWaitArguments(socketPath: String, terminalID: String, pattern: String, timeoutMs: Int?) -> CloudTuiRequest {
        var fields: [String: Any] = ["terminal": terminalID, "pattern": pattern]
        if let timeoutMs { fields["timeout_ms"] = String(timeoutMs) }
        return CloudTuiRequest("terminal.wait", fields)
    }
    static func processWaitArguments(socketPath: String, terminalID: String, timeoutMs: Int?) -> CloudTuiRequest {
        var fields: [String: Any] = ["terminal": terminalID]
        if let timeoutMs { fields["timeout_ms"] = String(timeoutMs) }
        return CloudTuiRequest("terminal.wait_exit", fields)
    }
    static func outputReadArguments(socketPath: String, terminalID: String, after: Int?, maxBytes: Int?) -> CloudTuiRequest {
        var fields: [String: Any] = ["terminal": terminalID]
        if let after, after >= 0 { fields["after"] = String(after) }
        if let maxBytes, maxBytes > 0 { fields["max_bytes"] = maxBytes }
        return CloudTuiRequest("terminal.output_read", fields)
    }
    static func legacyListWorkspacesArguments(socketPath: String) -> CloudTuiRequest { CloudTuiRequest("list-workspaces", raw: true) }
    static func identifyArguments(socketPath: String) -> CloudTuiRequest? { CloudTuiRequest("identify", raw: true) }
    static func listeningPortsArguments(socketPath: String) -> CloudTuiRequest? { CloudTuiRequest("machine-listening-tcp", raw: true) }
    static func resolveTerminalArguments(socketPath: String, terminalID: String) -> CloudTuiRequest? {
        let payload = terminalID.hasPrefix("term_") ? String(terminalID.dropFirst(5)) : terminalID
        guard payload.utf8.count == 32, payload.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return CloudTuiRequest("resolve-terminal", ["terminal_id": "term_" + payload], raw: true)
    }
    static func setDefaultColorsArguments(socketPath: String, foreground: String?, background: String?) -> CloudTuiRequest? {
        var fields: [String: Any] = [:]
        if let foreground { fields["foreground"] = foreground }
        if let background { fields["background"] = background }
        return fields.isEmpty ? nil : CloudTuiRequest("session.terminal_defaults.update", fields, mutation: true)
    }
}
