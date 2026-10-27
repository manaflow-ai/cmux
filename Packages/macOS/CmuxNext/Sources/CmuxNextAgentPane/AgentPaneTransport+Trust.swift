import Foundation

extension AgentPaneTransport {
    /// Records the user's explicit local folder pick in acpmux. The relay normally requires a
    /// page gesture for `acp.trust.set`; this request is made by the native folder picker after
    /// that picker returned a concrete folder, so it carries the same local-app/person proof and
    /// cannot be reached by an arbitrary page path. Remote wires and page-script picks never call
    /// this helper.
    func trustPicked(_ folder: String) async {
        guard !remoteWire, let socket, let ids = requestIds else { return }
        let id = ids.hostID()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "acp.trust.set",
            "params": ["cwd": folder, "level": "trusted"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes]) else {
            return
        }
        let error = await submitHost(connection: current, frame: String(decoding: data, as: UTF8.self))
        if let error {
            Self.logger.error("agent pane automatic folder trust failed: \(error.rawValue, privacy: .public)")
        }
    }
}
