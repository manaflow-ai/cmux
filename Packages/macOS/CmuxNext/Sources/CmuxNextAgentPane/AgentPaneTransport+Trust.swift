import Foundation

extension AgentPaneTransport {
    /// Records the user's explicit local folder pick in acpmux. The relay normally requires a
    /// page gesture for `acp.trust.set`; this request is made by the native folder picker after
    /// that picker returned a concrete folder, so it carries the same local-app/person proof and
    /// cannot be reached by an arbitrary page path. Remote wires and page-script picks never call
    /// this helper.
    func trustPicked(_ folder: String) async {
        guard !remoteWire else { return }
        guard let socket, !socket.isClosed, sentFirst, let ids = requestIds else {
            if !pendingTrustFolders.contains(folder) { pendingTrustFolders.append(folder) }
            return
        }
        guard let request = trustRequest(folder, ids: ids) else { return }
        let error = await submitHost(connection: current, requestID: request.id, folder: folder, frame: request.frame)
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
            pendingHost.append(PendingHostSend(connection: current, requestID: request.id, folder: folder, frame: request.frame, reply: nil))
        }
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

    func submitHost(connection id: Int, requestID: Int, folder: String, frame: String) async -> AgentPaneTransportError? {
        await withCheckedContinuation { continuation in
            pendingHost.append(PendingHostSend(connection: id, requestID: requestID, folder: folder, frame: frame, reply: continuation))
            guard !draining else { return }
            draining = true
            Task { [weak self] in await self?.drain() }
        }
    }

    final class PendingHostSend {
        let connection: Int
        let requestID: Int
        let folder: String
        let frame: String
        var completion: CheckedContinuation<Void, Never>?
        let reply: CheckedContinuation<AgentPaneTransportError?, Never>?

        init(connection: Int, requestID: Int, folder: String, frame: String, reply: CheckedContinuation<AgentPaneTransportError?, Never>?) {
            self.connection = connection
            self.requestID = requestID
            self.folder = folder
            self.frame = frame
            self.reply = reply
        }
    }

    func hostAnswered(_ id: Int, connection: Int, error: AgentPaneTransportError? = nil) {
        guard let host = awaitingHost[id], host.connection == connection else { return }
        awaitingHost.removeValue(forKey: id)
        host.reply?.resume(returning: error)
        host.completion?.resume()
    }

    func sendHost(_ host: PendingHostSend, socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async {
        let requestID = host.requestID
        let connection = host.connection
        await withCheckedContinuation { completion in
            host.completion = completion
            awaitingHost[requestID] = host
            ids.whenResult(requestID) { [weak self] success in
                Task { @MainActor in self?.hostAnswered(requestID, connection: connection, error: success ? nil : .methodRefused) }
            }
            if let error = socket.send(host.frame) {
                ids.cancel(requestID)
                hostAnswered(requestID, connection: connection, error: error)
            }
        }
    }

    func failHostRequests(connection id: Int) {
        let waiting = awaitingHost.values.filter { $0.connection == id }
        for host in waiting {
            if !pendingTrustFolders.contains(host.folder) { pendingTrustFolders.append(host.folder) }
            requestIds?.cancel(host.requestID)
            hostAnswered(host.requestID, connection: id, error: .closed)
        }
        for host in pendingHost where host.connection == id {
            if !pendingTrustFolders.contains(host.folder) { pendingTrustFolders.append(host.folder) }
            host.reply?.resume(returning: .closed)
        }
        pendingHost.removeAll { $0.connection == id }
        if let personProofID {
            requestIds?.cancelAndNotify(personProofID)
            self.personProofID = nil
        }
    }
}
