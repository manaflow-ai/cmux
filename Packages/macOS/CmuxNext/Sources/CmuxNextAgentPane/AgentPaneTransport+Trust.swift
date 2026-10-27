import Foundation

extension AgentPaneTransport {
    /// Records the user's explicit local folder pick in acpmux. The relay normally requires a
    /// page gesture for `acp.trust.set`; this request is made by the native folder picker after
    /// that picker returned a concrete folder, so it carries the same local-app/person proof and
    /// cannot be reached by an arbitrary page path. Remote wires and page-script picks never call
    /// this helper.
    func trustPicked(_ folder: String) async {
        guard !remoteWire else { return }
        guard let ids = requestIds else {
            if !pendingTrustFolders.contains(folder) { pendingTrustFolders.append(folder) }
            return
        }
        guard let request = trustRequest(folder, ids: ids) else { return }
        let error = await submitHost(connection: current, requestID: request.id, frame: request.frame)
        if let error {
            Self.logger.error("agent pane automatic folder trust failed: \(error.rawValue, privacy: .public)")
        }
    }

    func flushPendingTrust() {
        guard !remoteWire, let ids = requestIds else { return }
        let folders = pendingTrustFolders
        pendingTrustFolders.removeAll()
        for folder in folders {
            guard let request = trustRequest(folder, ids: ids) else { continue }
            pendingHost.append(PendingHostSend(connection: current, requestID: request.id, frame: request.frame, reply: nil))
        }
        guard !draining, !pendingHost.isEmpty else { return }
        draining = true
        Task { [weak self] in await self?.drain() }
    }

    private func trustRequest(_ folder: String, ids: AcpmuxRequestIds) -> (id: Int, frame: String)? {
        let id = ids.hostID()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "acp.trust.set",
            "params": ["cwd": folder, "level": "trusted"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        return (id, String(decoding: data, as: UTF8.self))
    }
}
