import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import os

/// Hands the paired phones' approval keys to acpmux (`_acpmux/approvers_set`,
/// acpmux `hub/approvers.rs`, cnx-ios verify/phone-approvals.md), so an Allow
/// the phone signed after Face ID counts there.
///
/// - Its own connection proves this launch's person key (acpmux `hub/person.rs`,
///   transport unix) on a socket whose server peer was checked first
///   (``AcpmuxCheckedLine``); only the person may set approvers.
/// - acpmux keeps approvers in memory only, so a restarted daemon starts with
///   none: the connection stays open, and each new one sends the list again.
/// - Nothing to sync (no paired phones) and no connection: it does not connect.
@MainActor
final class CnxApproverSync {
    private let environment: AcpmuxEnvironment
    private var connection: AcpmuxCheckedLine?
    private var proven = false
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
    /// The last `approvers_set` params; nil until the first update.
    private var params: [String: Any]?
    private var hasApprovers: Bool { (params?["approvers"] as? [Any])?.isEmpty == false }
    private var nextID = 10
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone.approvers")

    init(environment: AcpmuxEnvironment) {
        self.environment = environment
    }

    nonisolated deinit {
        reconnect?.cancel()
        connection?.cancel()
    }

    /// The approvers acpmux should hold now (``CnxPairedDevices/approversParams(macDevice:)``).
    func update(_ params: [String: Any]) {
        self.params = params
        if proven {
            send()
        } else if connection == nil, reconnect == nil, hasApprovers {
            connect()
        }
    }

    /// Stops syncing (sign-out, iPhone connections off). acpmux keeps what it has
    /// until ``update(_:)`` sends an empty list or the daemon restarts.
    func stop() {
        reconnect?.cancel()
        reconnect = nil
        connection?.cancel()
        connection = nil
        proven = false
    }

    private func connect() {
        reconnect = nil
        guard FileManager.default.fileExists(atPath: environment.socketPath) else { return scheduleReconnect() }
        let line = AcpmuxCheckedLine(environment: environment)
        connection = line
        proven = false
        line.start(send: Self.frame(id: 1, method: "initialize", params: [
            "protocolVersion": 1, "clientInfo": ["name": "cmux-next-iphone-approvers", "version": "1"],
            "clientCapabilities": [String: Any](),
        ]), onLine: { [weak self] data in Task { @MainActor in self?.handle(data, on: line) } },
           onClose: { [weak self] in Task { @MainActor in self?.lost(line) } })
    }

    private static func frame(id: Int, method: String, params: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method,
                                                                 "params": params])) ?? Data()
        data.append(0x0A)
        return data
    }

    private func handle(_ data: Data, on line: AcpmuxCheckedLine) {
        guard connection === line,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (message["id"] as? NSNumber)?.intValue else { return }
        switch id {
        case 1:
            let meta = ((message["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            let challenge = meta?["personChallenge"] as? [String: Any]
            guard let nonce = challenge?["nonce"] as? String, let connectionID = challenge?["connection"] as? String,
                  let proof = line.personProof(nonce: nonce, connection: connectionID) else {
                logger.error("no person challenge or no key for this daemon; retrying")
                line.cancel()
                return lost(line)
            }
            line.send(Self.frame(id: 2, method: "_acpmux/person_prove", params: ["proof": proof]))
        case 2:
            guard (message["result"] as? [String: Any])?["person"] as? Bool == true else {
                logger.error("acpmux refused the person proof; retrying")
                line.cancel()
                return lost(line)
            }
            proven = true
            backoff.reset()
            send()
        default:
            if let error = message["error"] as? [String: Any] {
                logger.error("approvers_set refused: \(String(describing: error["message"]), privacy: .public)")
            } else {
                let count = ((message["result"] as? [String: Any])?["count"] as? NSNumber)?.intValue ?? -1
                logger.info("acpmux holds \(count, privacy: .public) phone approvers")
            }
        }
    }

    private func send() {
        guard let connection, proven, let params else { return }
        nextID += 1
        connection.send(Self.frame(id: nextID, method: "_acpmux/approvers_set", params: params))
    }

    private func lost(_ line: AcpmuxCheckedLine) {
        guard connection === line else { return }
        connection = nil
        proven = false
        if hasApprovers { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        // task-owner: CnxApproverSync.reconnect: one backoff wait after a lost, refused or absent socket.
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "iphone-approvers.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }
}
