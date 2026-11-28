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
        /// The page could not be made ready in time: commands get errors.
        case failed(String)
    }

    let generation: Int
    var phase = Phase.preparing
    var map = CDPRawIDMap()
    /// Host commands that arrived while preparing (bounded).
    var queued: [String] = []
    var deadline: DemandTimer?
    var preparing: Task<Void, Never>?

    static let queueLimit = 256
}

extension BrowserHostProvider {
    /// `cdp.attach`: the agent's first touch of a CEF tab. The page becomes
    /// agent-ready (marked, rebuilt if a password could be filled, created
    /// in the background if never shown) before any CDP message reaches it;
    /// host commands wait in a bounded queue until then, or until the
    /// prepare deadline answers them with CDP errors.
    func attachRelay(_ targetID: String) {
        // Only a Chromium tab this app announced (never an incognito or
        // another machine's tab): anything else stays unattached, so its
        // commands get CDP errors, and it is never marked or prepared.
        guard announced[targetID]?.engine == .cef else { return }
        marking?.agentWillDrive(targetID: targetID)
        guard relays[targetID] == nil else { return }
        relayGeneration += 1
        let gen = relayGeneration
        var session = RelaySession(generation: gen, map: CDPRawIDMap(firstRawID: rawIDCursor[targetID]))
        let deadline = DemandTimer(owner: "browser-host.relay-prepare", clock: clock)
        deadline.schedule(after: prepareDeadline) { @MainActor [weak self] in
            self?.prepareFailed(targetID, gen, "the tab's page did not start in time")
        }
        session.deadline = deadline
        let relay = relay
        session.preparing = Task { [weak self] in
            let ready = await relay?.prepareRelay(targetID: targetID) ?? false
            self?.prepared(targetID, gen, ready)
        }
        relays[targetID] = session
    }

    private func prepared(_ targetID: String, _ gen: Int, _ ready: Bool) {
        guard var session = relays[targetID], session.generation == gen, case .preparing = session.phase else { return }
        guard ready, let relay,
              relay.startRelay(targetID: targetID,
                               onMessage: { [weak self] message in self?.relayFromBrowser(targetID, gen, message) },
                               onEnd: { [weak self] in self?.relayClosedByBrowser(targetID, gen) }) else {
            prepareFailed(targetID, gen, "the tab is not a Chromium tab, or its page could not start")
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
        case .relaying:
            break
        }
        guard let out = session.map.outbound(message) else {
            logger.notice("browser host provider: cdp message without an integer id dropped (\(targetID, privacy: .public))")
            return
        }
        // Stored before the send: a reply may arrive while it runs.
        relays[targetID] = session
        rawIDCursor[targetID] = session.map.nextRawID
        let result = relay?.send(targetID: targetID, message: out.message) ?? .noBrowser
        if result != .sent { relays[targetID]?.map.forget(rawID: out.rawID) }
        switch result {
        case .sent: break
        case .noBrowser: replyError(targetID, to: message, "the tab's page has no browser")
        case .refused: replyError(targetID, to: message, "Chromium refused the message")
        }
    }

    /// A raw message from the tab's browser: replies get the host's id back,
    /// events pass unchanged, replies the host never asked for are dropped.
    private func relayFromBrowser(_ targetID: String, _ gen: Int, _ message: String) {
        guard var session = relays[targetID], session.generation == gen else { return }
        let forward = session.map.inbound(message)
        relays[targetID] = session
        if let forward { send(.cdp(targetID: targetID, message: forward)) }
    }

    /// The browser went away under a live relay (rebuilt, closed): the host
    /// drops its driver for the tab and attaches again on its next call.
    private func relayClosedByBrowser(_ targetID: String, _ gen: Int) {
        guard var session = relays[targetID], session.generation == gen else { return }
        relays[targetID] = nil
        session.deadline?.cancel()
        // Every command still waiting is answered before the host hears the close.
        for waiting in session.map.drainPending() { replyError(targetID, waiting, "the tab's page closed") }
        send(.event(name: "tab.relay.closed", payload: .object(["targetId": .string(targetID)])))
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
        guard var session = relays.removeValue(forKey: targetID) else { return }
        session.deadline?.cancel()
        session.preparing?.cancel()
        if case .relaying = session.phase { relay?.stopRelay(targetID: targetID) }
        guard answering else { return }
        for message in session.queued { replyError(targetID, to: message, "the tab closed") }
        for waiting in session.map.drainPending() { replyError(targetID, waiting, "the tab closed") }
    }

    private func replyError(_ targetID: String, to message: String, _ text: String) {
        guard let reply = CDPRawIDMap.errorReply(to: message, text: text) else { return }
        send(.cdp(targetID: targetID, message: reply))
    }

    private func replyError(_ targetID: String, _ waiting: (hostID: Int, sessionID: String?), _ text: String) {
        guard let reply = CDPRawIDMap.errorReply(hostID: waiting.hostID, sessionID: waiting.sessionID, text: text) else { return }
        send(.cdp(targetID: targetID, message: reply))
    }
}
