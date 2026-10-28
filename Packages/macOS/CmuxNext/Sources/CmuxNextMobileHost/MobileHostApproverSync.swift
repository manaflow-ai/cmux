import CmuxNextAgentPane
import CmuxNextCompat
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
/// - Nothing to sync (no paired phones) and no connection: it does not connect.
@MainActor
final class MobileHostApproverSync {
    private let environment: AcpmuxEnvironment
    /// The app's main-thread scheduler: each line and close of the connection is one automation task (acpmux's
    /// replies, which a phone's approval waits on).
    private let mainWork: MainWorkScheduler
    /// The owner of the connection's tasks (its lines, its close, a refused proof), interned once.
    private let lineOwner: MainTaskOwner
    private var connection: AcpmuxCheckedLine?
    private var proven = false
    /// The backoff wait after a lost, refused or absent socket.
    private let reconnect: MainDeadline
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
    }
    private var nextID = 10
    /// Connections tried so far, the backoff's included (tests, diagnostics).
    private(set) var connectAttempts = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.iphone.approvers")

    /// - Parameter deadlines: The app's one deadline placer; its scheduler runs the connection's replies.
    init(environment: AcpmuxEnvironment, deadlines: MainDeadlineScheduler) {
        self.environment = environment
        mainWork = deadlines.work
        lineOwner = deadlines.work.board.owner("iphone-approvers.line")
        reconnect = MainDeadline(owner: "iphone-approvers.reconnect", workClass: .automation, scheduler: deadlines)
    }

    // A released deadline never fires (its wake holds it weakly), so only the connection ends here.
    nonisolated deinit {
        connection?.cancel()
    }

    /// The approvers acpmux should hold now (``MobileHostPairedDevices/approversParams(macDevice:)``).
    func update(_ params: [String: Any]) {
        self.params = params
        if proven {
            send()
        } else if connection == nil, !reconnect.isScheduled, needed {
            connect()
        }
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
        } else if connection == nil, !reconnect.isScheduled, needed {
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
        } else if connection == nil, !reconnect.isScheduled, needed {
            connect()
        }
    }

    /// Stops syncing (sign-out, iPhone connections off). acpmux keeps what it has
    /// until ``update(_:)`` sends an empty list or the daemon restarts.
    func stop() {
        reconnect.cancel()
        connection?.cancel()
        connection = nil
        proven = false
    }

    private func connect() {
        connectAttempts += 1
        reconnect.cancel()
        guard FileManager.default.fileExists(atPath: environment.socketPath) else { return scheduleReconnect() }
        let line = AcpmuxCheckedLine(environment: environment)
        connection = line
        proven = false
        // The line's queue delivers each line and the close in order; each is one task, in that order.
        let mainWork = mainWork, owner = lineOwner
        line.start(send: Self.frame(id: 1, method: "initialize", params: [
            "protocolVersion": 1, "clientInfo": ["name": "cmux-next-iphone-approvers", "version": "1"],
            "clientCapabilities": [String: Any](),
        ]), onLine: { [weak self] data in mainWork.postFromAnyThread(.automation, owner: owner) { [weak self] in self?.handle(data, on: line) } },
           onClose: { [weak self] in mainWork.postFromAnyThread(.automation, owner: owner) { [weak self] in self?.lost(line) } })
    }

    private nonisolated static func frame(id: Int, method: String, params: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method,
                                                                 "params": params])) ?? Data()
        data.append(0x0A)
        return data
    }

    private func handle(_ data: Data, on line: AcpmuxCheckedLine) {
        guard connection === line,
              let message = try? JSONSerialization.blockingJSONObject(with: data) as? [String: Any],
              let id = (message["id"] as? NSNumber)?.intValue else { return }
        switch id {
        case 1:
            let meta = ((message["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            let challenge = meta?["personChallenge"] as? [String: Any]
            guard let nonce = challenge?["nonce"] as? String, let connectionID = challenge?["connection"] as? String else {
                return refused(line)
            }
            // The proof is made and sent on the line's queue; a refusal comes back here, as the line's own lines do.
            let mainWork = mainWork, owner = lineOwner
            line.sendPersonProof(nonce: nonce, connection: connectionID, request: { proof in
                Self.frame(id: 2, method: "_acpmux/person_prove", params: ["proof": proof])
            }, refused: { [weak self] in
                mainWork.postFromAnyThread(.automation, owner: owner) { [weak self] in self?.refused(line) }
            })
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
                logger.error("acpmux refused a person update: \(String(describing: error["message"]), privacy: .public)")
            } else {
                let count = ((message["result"] as? [String: Any])?["count"] as? NSNumber)?.intValue ?? -1
                logger.info("acpmux took \(count, privacy: .public) approvers or workspace folders")
            }
        }
    }

    /// No person proof for `line` (no challenge, or no key for this daemon): ends it and retries later.
    private func refused(_ line: AcpmuxCheckedLine) {
        guard connection === line else { return }
        logger.error("no person challenge or no key for this daemon; retrying")
        line.cancel()
        lost(line)
    }

    private func send() {
        sendRoots()
        sendPicks()
        guard let connection, proven, let params else { return }
        nextID += 1
        connection.send(Self.frame(id: nextID, method: "_acpmux/approvers_set", params: params))
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
        if needed { scheduleReconnect() }
    }

    /// One backoff wait after a lost, refused or absent socket, then a new connection.
    private func scheduleReconnect() {
        reconnect.schedule(after: backoff.next()) { [weak self] in self?.connect() }
    }
}
