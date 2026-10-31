import CmuxNextAgentPane
import CmuxNextWakeups
import Foundation
import os

/// Hands the paired phones' approval keys to acpmux (`_acpmux/approvers_set`,
/// acpmux `hub/approvers.rs`, cmux-next-ios verify/phone-approvals.md), so an Allow
/// the phone signed after Face ID counts there.
///
/// - Its own connection proves this launch's person key (acpmux `hub/person.rs`,
///   transport unix) on a socket whose server peer was checked first
///   (``AcpmuxCheckedLine``); only the person may set approvers.
/// - acpmux keeps approvers in memory only, so a restarted daemon starts with
///   none: the connection stays open, and each new one sends the list again.
/// - Nothing to sync (no paired phones) and no connection: it does not connect, once it has
///   listed acpmux's phone records (``MobileHostPhoneCredentials``).
/// - Each paired phone the account lists gets its own acpmux credential
///   (``MobileHostPhoneCredentials``), handed to hostd, so the phone's Full-access setting
///   (Settings > Devices, off by default) can cover it.
@MainActor
final class MobileHostApproverSync {
    private let environment: AcpmuxEnvironment
    private var connection: AcpmuxCheckedLine?
    private var proven = false
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
    /// The last `approvers_set` params; nil until the first update.
    private var params: [String: Any]?
    private var hasApprovers: Bool { (params?["approvers"] as? [Any])?.isEmpty == false }
    /// The folders of this Mac's workspaces a phone may start agent chats in
    /// (`_acpmux/workspace_roots_set`); nil until the first update.
    private var workspaceRoots: [String]?
    /// acpmux may still hold folders this sync sent: an empty list must reach it once,
    /// even with no approvers and no folders left (iPhone connections turned off).
    private var rootsClearPending = false
    /// The agent and model this Mac picked last for a new chat (`_acpmux/new_chat_picks_set`);
    /// nil until the first update.
    private var newChatPicks: [String: Any]?
    /// acpmux may still hold picks this sync sent: an empty set must reach it once.
    private var picksClearPending = false
    private var needed: Bool {
        hasApprovers || workspaceRoots?.isEmpty == false || rootsClearPending || newChatPicks != nil || picksClearPending
            || credentials.needsConnection
    }
    /// Hands hostd every phone's credential, by phone device id, whenever the set changes.
    var phoneCredentialsChanged: (@MainActor ([String: String]) -> Void)?
    /// The phones' own acpmux credentials and their records' revocations.
    private var credentials = MobileHostPhoneCredentials()
    /// The credentials hostd holds now.
    private var handedTokens: [String: String] = [:]
    private var nextID = 10
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone.approvers")

    init(environment: AcpmuxEnvironment) {
        self.environment = environment
    }

    nonisolated deinit {
        reconnect?.cancel()
        connection?.cancel()
    }

    /// The approvers acpmux should hold now (``MobileHostPairedDevices/approversParams(macDevice:)``).
    func update(_ params: [String: Any]) {
        self.params = params
        if proven {
            send()
        } else if connection == nil, reconnect == nil, needed {
            connect()
        }
    }

    /// The paired phones (link ids) and, once the account's list is read, the ones it lists
    /// (``MobileHostPairedDevices/listed(in:)``): each listed one gets its own credential; one that
    /// left has its record revoked.
    func updatePhones(paired: Set<String>, listed: Set<String>?) {
        run(credentials.update(paired: paired, listed: listed, ids: &nextID))
        if !proven, connection == nil, reconnect == nil, needed { connect() }
    }

    /// The folders of the workspaces the daemon lists now (each tab's folder). acpmux lets
    /// a remote connection (a phone, through cmux-mobile-host) start sessions there, under its own
    /// guards: never `/`, the home folder or above it; symlinks resolved.
    func updateWorkspaceRoots(_ roots: [String]) {
        guard roots != workspaceRoots else { return }
        if roots.isEmpty, workspaceRoots?.isEmpty == false { rootsClearPending = true }
        workspaceRoots = roots
        if proven {
            sendRoots()
        } else if connection == nil, reconnect == nil, needed {
            connect()
        }
    }

    /// The agent and model this Mac's New Tab page picked last (``NewChatPicks/params``);
    /// nil (iPhone connections off, signed out, nothing picked) clears what acpmux holds.
    func updateNewChatPicks(_ params: [String: Any]?) {
        if params == nil {
            guard newChatPicks != nil || picksClearPending else { return }
            picksClearPending = true
        }
        newChatPicks = params
        if proven {
            sendPicks()
        } else if connection == nil, reconnect == nil, needed {
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
        credentials.disconnected()
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
            // A refusal retried on this connection keeps the backoff growing.
            if !credentials.refused { backoff.reset() }
            run(credentials.connected(ids: &nextID))
            send()
        default:
            if let requests = credentials.reply(id: id, message, ids: &nextID) {
                guard credentials.refused else { return run(requests) }
                let error = message["error"] as? [String: Any]
                logger.error("acpmux refused a phone credential request: \(String(describing: error?["message"]), privacy: .public); retrying")
                // A new connection retries it, after the backoff.
                run([])
                line.cancel()
                return lost(line)
            }
            if let error = message["error"] as? [String: Any] {
                logger.error("acpmux refused a person update: \(String(describing: error["message"]), privacy: .public)")
            } else {
                let count = ((message["result"] as? [String: Any])?["count"] as? NSNumber)?.intValue ?? -1
                logger.info("acpmux took \(count, privacy: .public) approvers or workspace folders")
            }
        }
    }

    private func send() {
        sendRoots()
        sendPicks()
        guard let connection, proven, let params else { return }
        nextID += 1
        connection.send(Self.frame(id: nextID, method: "_acpmux/approvers_set", params: params))
    }

    /// Sends the credential requests (only on the proven connection), then hands hostd the
    /// credentials whenever they changed.
    private func run(_ requests: [MobileHostPhoneCredentials.Request]) {
        if let connection, proven {
            for request in requests { connection.send(Self.frame(id: request.id, method: request.method, params: request.params)) }
        }
        let tokens = credentials.tokens
        guard tokens != handedTokens else { return }
        handedTokens = tokens
        phoneCredentialsChanged?(tokens)
    }

    private func sendRoots() {
        guard let connection, proven, let workspaceRoots else { return }
        nextID += 1
        connection.send(Self.frame(id: nextID, method: "_acpmux/workspace_roots_set", params: ["roots": workspaceRoots]))
        if workspaceRoots.isEmpty { rootsClearPending = false }
    }

    private func sendPicks() {
        guard let connection, proven, newChatPicks != nil || picksClearPending else { return }
        nextID += 1
        connection.send(Self.frame(id: nextID, method: "_acpmux/new_chat_picks_set", params: newChatPicks ?? [:]))
        if newChatPicks == nil { picksClearPending = false }
    }

    private func lost(_ line: AcpmuxCheckedLine) {
        guard connection === line else { return }
        connection = nil
        proven = false
        credentials.disconnected()
        if needed { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        // task-owner: MobileHostApproverSync.reconnect: one backoff wait after a lost, refused or absent socket.
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "iphone-approvers.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }
}
