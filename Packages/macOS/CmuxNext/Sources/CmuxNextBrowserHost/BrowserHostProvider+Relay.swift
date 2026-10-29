import CmuxNextBrowser
import CmuxNextBrowserAutomation
import CmuxNextWakeups
import Foundation

/// One CEF tab's DevTools relay on the current link.
struct RelaySession {
    enum Phase {
        /// `cdp.attach` arrived; the app makes the page agent-ready first.
        case preparing
        case relaying
        /// The Chromium Host relays the tab's CDP to the browser host itself (`cdp.prepare`):
        /// the app keeps only the tab's agent-ready state and capture votes.
        case direct
        /// The page could not be made ready in time: commands get errors.
        case failed(String)
    }

    let generation: Int
    var phase = Phase.preparing
    /// Started by `cdp.prepare`: once ready, the tab goes to ``Phase/direct``, never to ``Phase/relaying``.
    var direct = false
    /// The id map, shared with the link's write queue (replies are mapped back there).
    let table: CDPRelayTable
    /// Host commands that arrived while preparing (bounded).
    var queued: [String] = []
    var deadline: MainDeadline?
    var preparing: Task<Void, Never>?
    /// The tab's capture votes for `Page.captureScreenshot` commands sent and not answered, by raw id.
    var screenshots: [Int: VisibilityCaptureVote] = [:]
    /// The tab's capture vote from `Page.startScreencast` until `Page.stopScreencast`.
    var screencast: VisibilityCaptureVote?

    static let queueLimit = 256

    /// The relay ended: every capture it held ends with it.
    func releaseCaptures() {
        for vote in screenshots.values { vote.release() }
        screencast?.release()
    }
}

extension BrowserHostProvider {
    /// `cdp.attach`: the agent's first touch of a CEF tab. The page becomes
    /// agent-ready (marked, rebuilt if a password could be filled, created
    /// in the background if never shown) before any CDP message reaches it;
    /// host commands wait in a bounded queue until then, or until the
    /// prepare deadline answers them with CDP errors.
    func attachRelay(_ targetID: String, direct: Bool = false) {
        // Only a Chromium tab this app announced (never an incognito or
        // another machine's tab): anything else stays unattached, so its
        // commands get CDP errors, and it is never marked or prepared.
        guard announced[targetID]?.engine == .cef else { return }
        marking?.agentWillDrive(targetID: targetID)
        guard relays[targetID] == nil else { return }
        relayGeneration += 1
        let gen = relayGeneration
        var session = RelaySession(generation: gen, table: CDPRelayTable(firstRawID: rawIDCursor[targetID]))
        session.direct = direct
        // An agent's request waits on it: automation, flexible (never sooner).
        let deadline = MainDeadline(owner: "browser-host.relay-prepare", workClass: .automation, scheduler: deadlines)
        deadline.schedule(after: prepareDeadline) { [weak self] in
            self?.prepareFailed(targetID, gen, "the tab's page did not start in time")
        }
        session.deadline = deadline
        let relay = relay
        // main-hop-allow: prepareRelay is the app's main-actor async page start (the tab's Chromium browser); the task only hands its answer to prepared
        session.preparing = Task { [weak self] in
            let ready = await relay?.prepareRelay(targetID: targetID) ?? false
            self?.prepared(targetID, gen, ready)
        }
        relays[targetID] = session
    }

    private func prepared(_ targetID: String, _ gen: Int, _ ready: Bool) {
        guard var session = relays[targetID], session.generation == gen, case .preparing = session.phase else { return }
        if session.direct {
            guard ready else {
                prepareFailed(targetID, gen, relay?.prepareFailure(targetID: targetID) ?? "the tab is not a Chromium tab, or its page could not start")
                return
            }
            session.deadline?.cancel()
            session.deadline = nil
            session.preparing = nil
            session.phase = .direct
            relays[targetID] = session
            answerDirect(targetID)
            return
        }
        guard ready, let relay,
              relay.startRelay(targetID: targetID,
                               onMessage: { [weak self] message in self?.relayFromBrowser(targetID, gen, message) },
                               onEnd: { [weak self] in self?.relayClosedByBrowser(targetID, gen) }) else {
            prepareFailed(targetID, gen, relay?.prepareFailure(targetID: targetID) ?? "the tab is not a Chromium tab, or its page could not start")
            return
        }
        session.deadline?.cancel()
        session.deadline = nil
        session.preparing = nil
        session.phase = .relaying
        let queued = session.queued
        session.queued = []
        relays[targetID] = session
        for message in queued { relayToBrowser(targetID, message) }
    }

    private func prepareFailed(_ targetID: String, _ gen: Int, _ reason: String) {
        guard var session = relays[targetID], session.generation == gen, case .preparing = session.phase else { return }
        session.deadline?.cancel()
        session.deadline = nil
        session.preparing?.cancel()
        session.preparing = nil
        guard !session.direct else {
            // The browser host holds the commands; it ends the relay and asks again on its next call.
            relays[targetID] = nil
            send(.event(name: "tab.relay.failed", payload: .object(["targetId": .string(targetID), "reason": .string(reason)])))
            return
        }
        session.phase = .failed(reason)
        let queued = session.queued
        session.queued = []
        relays[targetID] = session
        for message in queued { replyError(targetID, to: message, reason) }
    }

    /// One host CDP message for a tab's browser, with its id moved into the
    /// shim's raw range.
    func relayToBrowser(_ targetID: String, _ message: String) {
        guard var session = relays[targetID] else {
            replyError(targetID, to: message, "the tab is not attached (cdp.attach first)")
            return
        }
        switch session.phase {
        case .preparing:
            guard session.queued.count < RelaySession.queueLimit else {
                replyError(targetID, to: message, "too many commands while the tab's page starts")
                return
            }
            session.queued.append(message)
            relays[targetID] = session
            return
        case .failed(let reason):
            replyError(targetID, to: message, reason)
            return
        case .direct:
            replyError(targetID, to: message, "the tab's CDP goes to the Chromium Host, not the app")
            return
        case .relaying:
            break
        }
        guard let out = session.table.outbound(message) else {
            logger.notice("browser host provider: cdp message without an integer id dropped (\(targetID, privacy: .public))")
            return
        }
        // Mapped before the send: a reply may arrive while it runs.
        rawIDCursor[targetID] = session.table.nextRawID
        // The vote is taken before the send, so a hidden tab renders for the capture.
        let captureCommand = CDPCaptureCommand(command: message)
        if let captureCommand { beginCapture(captureCommand, targetID, rawID: out.rawID) }
        let result = relay?.send(targetID: targetID, message: out.message) ?? .noBrowser
        if result != .sent {
            session.table.forget(rawID: out.rawID)
            if let captureCommand { abandonCapture(captureCommand, targetID, rawID: out.rawID) }
        }
        switch result {
        case .sent: break
        case .noBrowser: replyError(targetID, to: message, "the tab's page has no browser")
        case .refused: replyError(targetID, to: message, "Chromium refused the message")
        }
    }

    /// A raw message from the tab's browser: replies get the host's id back,
    /// events pass unchanged, replies the host never asked for are dropped.
    /// The main actor only queues it: the id scan, the rewrite and the encode
    /// run on the link's write queue, in order with every other frame.
    private func relayFromBrowser(_ targetID: String, _ gen: Int, _ message: String) {
        guard let session = relays[targetID], session.generation == gen else { return }
        let table = session.table
        guard !session.screenshots.isEmpty else {
            send { table.inbound(message).map { [.cdp(targetID: targetID, message: $0)] } ?? [] }
            return
        }
        // A screenshot is pending: the write queue, which reads the reply's id, posts one automation
        // task when this message answers it.
        let pending = Set(session.screenshots.keys)
        let (work, owner) = (mainWork, captureTaskOwner)
        let answered: @MainActor @Sendable (Int) -> Void = { [weak self] rawID in
            self?.screenshotAnswered(targetID, gen, rawID)
        }
        send {
            let reply = table.inboundReply(message)
            if let rawID = reply.rawID, pending.contains(rawID) {
                // node-free: the vote's end; the agent waits on the reply, never on a frame.
                work.postFromAnyThread(.automation, owner: owner) { answered(rawID) }
            }
            return reply.message.map { [.cdp(targetID: targetID, message: $0)] } ?? []
        }
    }

    // MARK: Capture votes

    private func beginCapture(_ command: CDPCaptureCommand, _ targetID: String, rawID: Int) {
        switch command {
        case .screenshot:
            relays[targetID]?.screenshots[rawID] = capture?.captureVote(targetID: targetID, reason: "agent.screenshot")
        case .startScreencast:
            guard relays[targetID]?.screencast == nil else { return }
            relays[targetID]?.screencast = capture?.captureVote(targetID: targetID, reason: "agent.screencast")
        case .stopScreencast:
            relays[targetID]?.screencast?.release()
            relays[targetID]?.screencast = nil
        }
    }

    /// A capture command the shim did not send ends its vote at once.
    private func abandonCapture(_ command: CDPCaptureCommand, _ targetID: String, rawID: Int) {
        switch command {
        case .screenshot:
            relays[targetID]?.screenshots.removeValue(forKey: rawID)?.release()
        case .startScreencast:
            relays[targetID]?.screencast?.release()
            relays[targetID]?.screencast = nil
        case .stopScreencast:
            break
        }
    }

    private func screenshotAnswered(_ targetID: String, _ gen: Int, _ rawID: Int) {
        guard relays[targetID]?.generation == gen else { return }
        relays[targetID]?.screenshots.removeValue(forKey: rawID)?.release()
    }

    /// The browser went away under a live relay (rebuilt, closed): the host
    /// drops its driver for the tab and attaches again on its next call.
    private func relayClosedByBrowser(_ targetID: String, _ gen: Int) {
        guard let session = relays[targetID], session.generation == gen else { return }
        relays[targetID] = nil
        session.deadline?.cancel()
        session.releaseCaptures()
        // Every command still waiting is answered before the host hears the close, after the
        // replies already queued (the drain runs on the write queue, behind them).
        let table = session.table
        send {
            Self.errorReplies(targetID, table.drainPending(), "the tab's page closed")
                + [.event(name: "tab.relay.closed", payload: .object(["targetId": .string(targetID)]))]
        }
    }

    /// `cdp.detach` from the host.
    func detachRelay(_ targetID: String) {
        guard relays[targetID] != nil else { return }
        endRelay(targetID)
    }

    /// Stops a relay (detach, tab gone, link down). `answering` sends a CDP
    /// error for every command still waiting (the tab left while the host
    /// still holds the relay).
    func endRelay(_ targetID: String, answering: Bool = false) {
        guard let session = relays.removeValue(forKey: targetID) else { return }
        session.deadline?.cancel()
        session.preparing?.cancel()
        session.releaseCaptures()
        if case .relaying = session.phase { relay?.stopRelay(targetID: targetID) }
        guard answering else { return }
        let (queued, table) = (session.queued, session.table)
        send {
            queued.compactMap { message in CDPRawIDMap.errorReply(to: message, text: "the tab closed").map { .cdp(targetID: targetID, message: $0) } }
                + Self.errorReplies(targetID, table.drainPending(), "the tab closed")
        }
    }

    /// CDP error replies for the host's commands still waiting on a relay.
    nonisolated static func errorReplies(_ targetID: String, _ waiting: [(hostID: Int, sessionID: String?)], _ text: String) -> [ProviderFrame] {
        waiting.compactMap { waiting in
            CDPRawIDMap.errorReply(hostID: waiting.hostID, sessionID: waiting.sessionID, text: text).map { .cdp(targetID: targetID, message: $0) }
        }
    }

    private func replyError(_ targetID: String, to message: String, _ text: String) {
        guard let reply = CDPRawIDMap.errorReply(to: message, text: text) else { return }
        send(.cdp(targetID: targetID, message: reply))
    }

}
