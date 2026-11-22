import Foundation

extension AgentPaneTransport {
    /// Records the user's explicit local folder pick in acpmux. The relay normally requires a
    /// page gesture for `acp.trust.set`; this request is made by the native folder picker after
    /// that picker returned a concrete folder, so it carries the same local-app/person proof and
    /// cannot be reached by an arbitrary page path. Remote wires and page-script picks never call
    /// this helper.
    func trustPicked(_ folder: String) async {
        guard !remoteWire else { return }
        let journal = promptJournal, daemon = socket?.isClosed == true ? nil : trustDaemon, connection = current
        // Persist at the pick, before joining a possibly busy drain. A queued request must
        // survive app exit even when sendHost has not started yet.
        let persisted = if let journal {
            await journal.trustIO { journal.recordPendingTrust(daemon: daemon, folder: folder) }
        } else { true }
        guard persisted, connection == current, daemon == trustDaemon,
              let socket, !socket.isClosed, sentFirst, let ids = requestIds else {
            rememberPendingTrust(folder, daemon: daemon)
            if !persisted {
                Self.logger.error("agent pane folder trust could not be journaled")
                if connection == current { close(connection: connection) }
            }
            return
        }
        guard let request = trustRequest(folder, ids: ids) else { return }
        let error = await submitHost(connection: current, requestID: request.id, folder: folder, frame: request.frame)
        if let error {
            Self.logger.error("agent pane automatic folder trust failed: \(error.rawValue, privacy: .public)")
        }
    }

    func restorePendingTrust(daemon: String, connection: Int) async -> Bool {
        let journal = promptJournal
        let restored = if let journal {
            await journal.trustIO { (journal.bindPreOpenTrust(daemon: daemon), journal.pendingTrustFolders(daemon: daemon)) }
        } else { (true, [String]()) }
        guard connection == current, !remoteWire else { return false }
        for folder in restored.1 { rememberPendingTrust(folder, daemon: daemon) }
        return restored.0
    }

    private func rememberPendingTrust(_ folder: String, daemon: String?) {
        let entry = AgentPanePromptJournal.PendingTrust(daemon: daemon ?? "", folder: folder)
        if !pendingTrustFolders.contains(entry) { pendingTrustFolders.append(entry) }
    }

    var hasPendingTrust: Bool {
        pendingTrustFolders.contains { $0.daemon.isEmpty || $0.daemon == trustDaemon }
    }

    func bindPreOpenTrust(to daemon: String) {
        for index in pendingTrustFolders.indices where pendingTrustFolders[index].daemon.isEmpty {
            pendingTrustFolders[index].daemon = daemon
        }
    }

    func flushPendingTrust() {
        guard !remoteWire, let ids = requestIds else { return }
        let folders = pendingTrustFolders.filter { $0.daemon.isEmpty || $0.daemon == trustDaemon }.map(\.folder)
        pendingTrustFolders.removeAll { $0.daemon.isEmpty || $0.daemon == trustDaemon }
        for folder in folders {
            guard let request = trustRequest(folder, ids: ids) else { continue }
            pendingHost.append(PendingHostSend(connection: current, requestID: request.id, folder: folder, daemon: trustDaemon, journal: promptJournal, frame: request.frame, reply: nil))
        }
    }

    func finishTrustBeforeReplay(socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async {
        while self.socket === socket, !socket.isClosed {
            flushPendingTrust()
            guard !pendingHost.isEmpty else { return }
            let host = pendingHost.removeFirst()
            guard host.connection == current else {
                host.reply?.resume(returning: .staleConnection)
                continue
            }
            await sendHost(host, socket: socket, ids: ids)
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
            pendingHost.append(PendingHostSend(connection: id, requestID: requestID, folder: folder, daemon: trustDaemon, journal: promptJournal, frame: frame, reply: continuation))
            guard !draining else { return }
            draining = true
            Task { [weak self] in await self?.drain() }
        }
    }

    final class PendingHostSend {
        let connection: Int
        let requestID: Int
        let folder: String
        let daemon: String?
        let journal: AgentPanePromptJournal?
        let frame: String
        var completion: CheckedContinuation<AgentPaneTransportError?, Never>?
        let reply: CheckedContinuation<AgentPaneTransportError?, Never>?

        init(connection: Int, requestID: Int, folder: String, daemon: String?, journal: AgentPanePromptJournal?, frame: String, reply: CheckedContinuation<AgentPaneTransportError?, Never>?) {
            self.connection = connection
            self.requestID = requestID
            self.folder = folder
            self.daemon = daemon
            self.journal = journal
            self.frame = frame
            self.reply = reply
        }
    }

    func hostAnswered(_ id: Int, connection: Int, error: AgentPaneTransportError? = nil) {
        guard let host = awaitingHost[id], host.connection == connection else { return }
        awaitingHost.removeValue(forKey: id)
        if error != nil { rememberPendingTrust(host.folder, daemon: host.daemon) }
        host.reply?.resume(returning: error)
        host.completion?.resume(returning: error)
    }

    func sendHost(_ host: PendingHostSend, socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async {
        let requestID = host.requestID
        let connection = host.connection
        let journal = host.journal, daemon = host.daemon, folder = host.folder
        // Capture the daemon and journal before suspension. Persist before the first send, so
        // a crash after refusal cannot leave a saved prompt without its trust barrier.
        let persisted = if let journal {
            await journal.trustIO { journal.recordPendingTrust(daemon: daemon, folder: folder) }
        } else { true }
        guard persisted, self.socket === socket, !socket.isClosed else {
            rememberPendingTrust(folder, daemon: daemon)
            host.reply?.resume(returning: .closed)
            if self.socket === socket { close(connection: connection) }
            return
        }
        let error = await withCheckedContinuation { completion in
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
        // Every unsuccessful completion retains consent and blocks both page sends and journal
        // replay. A reconnect retries it; a refusal must not look like a successful trust barrier.
        if error != nil {
            if self.socket === socket { close(connection: connection) }
        } else if let journal {
            await journal.trustIO { journal.clearPendingTrust(daemon: daemon, folder: folder) }
        }
    }

    func failHostRequests(connection id: Int) {
        let waiting = awaitingHost.values.filter { $0.connection == id }
        for host in waiting {
            requestIds?.cancel(host.requestID)
            hostAnswered(host.requestID, connection: id, error: .closed)
        }
        for host in pendingHost where host.connection == id {
            rememberPendingTrust(host.folder, daemon: host.daemon)
            host.reply?.resume(returning: .closed)
        }
        pendingHost.removeAll { $0.connection == id }
        if let personProofID {
            requestIds?.cancelAndNotify(personProofID)
            self.personProofID = nil
        }
    }
}
