import Foundation
import os
import Synchronization

/// One page frame through the relay: the off-main checks and the main-actor decisions.
extension AgentPaneTransport {
    // MARK: One page frame

    /// What the off-main work needs from the main actor: small values and thread-safe handles.
    nonisolated struct Snapshot: Sendable {
        var isFirst: Bool
        var localAppToken: String?
        var modeFields: Set<String>?
        var sessions: AcpmuxPaneSessions
        var options: AcpmuxPermissionOptions
    }

    /// What the main actor learns about a frame that needs its state: small values, never the frame.
    nonisolated struct Facts: Sendable {
        /// The connection's first frame (the main actor marks it sent).
        var isFirst = false
        var method: String?
        var pageID: String?
        /// The gesture ticket the frame carried (already stripped from it), and whether its `_meta`
        /// held anything else (R1).
        var ticket: String?
        var otherMeta = false
        var pick: AgentPaneGesturePick?
        var sessionId: String?
        var needsGesture = false
        var needsPathCheck = false
        var setting: Setting?
        /// An attach of a session that is not the pane's yet (only a gesture brings it in).
        var attachSession: String?
        /// A fork or handoff from a session outside the pane's scope (it uses the click's scope
        /// credit), and the handoff it names, if any.
        var foreignSource = false
        var handoffId: String?
        /// `_acpmux/harness_enable`: the native sheet decides it (``confirmHarnessEnable(_:)``).
        var harnessEnable = false

        /// No main-actor state decides this frame: it is checked, encoded and sent in one step.
        var free: Bool {
            ticket == nil && !needsGesture && !needsPathCheck && setting == nil && attachSession == nil && !foreignSource
                && !harnessEnable
        }
    }

    /// A mode or config option the frame sets (R2, P2), with the sheet's text.
    nonisolated struct Setting: Sendable {
        var sessionId: String?
        var configId: String
        var value: String?
        var asked: AgentPaneModeConfirmation
    }

    /// The decided frame, under its own lock. The main actor never reads it; the off-main stages
    /// of its step get only what the lock hands out: the encoded text, or a yes or no.
    nonisolated final class FrameBox: Sendable {
        private let frame: Mutex<[String: Any]>

        init(_ object: sending [String: Any]) { frame = Mutex(object) }

        /// The frame's fresh serialization, with `id` set when given; nil when it does not encode.
        func encoded(id: Int?) -> String? {
            frame.withLock { object in
                var copy = object
                if let id { copy["id"] = id }
                return AcpmuxRequestIds.encode(copy)
            }
        }

        /// Replaces the frame with the parse of `text`; false when `text` is not one JSON object.
        func replace(withJSON text: String) -> Bool {
            frame.withLock { object in
                guard let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return false }
                object = parsed
                return true
            }
        }

        /// Frees a large frame here, off the main thread.
        func free() { frame.withLock { $0 = [:] } }

        /// A string param of the frame (after the folder check made folders canonical).
        func param(_ key: String) -> String? {
            frame.withLock { (($0["params"] as? [String: Any])?[key] as? String) }
        }

        /// Sets a string param of the frame.
        func setParam(_ key: String, _ value: String) {
            frame.withLock { object in
                var params = object["params"] as? [String: Any] ?? [:]
                params[key] = value
                object["params"] = params
            }
        }
    }

    /// What one off-main pass over the line's frames did: the results of the frames it finished,
    /// in order, whether the connection's first frame went out, and the frame that waits for the
    /// main actor (if any).
    nonisolated struct Batch: Sendable {
        var outcomes: [Step] = []
        var firstSent = false
        var next: Next?
    }

    nonisolated enum Next: Sendable {
        /// The main actor decides this frame.
        case decide(Facts, FrameBox)
        /// A refused frame whose ticket the main actor spends.
        case spend(String, AcpmuxPaneMethods.Decision)
    }

    nonisolated enum Analysis: Sendable {
        /// Refused before the main actor (a ticket in it, if any, is to be spent).
        case refuse(AcpmuxPaneMethods.Decision, spend: String?)
        /// Sent already (a free frame), or the socket's error.
        case sent(AgentPaneTransportError?)
        /// The main actor decides.
        case decide(Facts, FrameBox)
    }

    /// Drains the send line in order. Off the main thread, one pass takes every waiting frame of the
    /// connection: the duplicate check, the one parse every rule reads, the rules that need no
    /// main-actor state, the re-encode and the send. It stops at the first frame that needs the main
    /// actor (the gesture record, the sheets, the pane's sessions), which gets only small facts.
    func drain() async {
        while let entry = pending.first {
            guard !entry.frames.isEmpty else {
                finishFirst()
                continue
            }
            guard entry.connection == current, let socket, let ids = requestIds else {
                complete(.stop(.staleConnection))
                continue
            }
            var texts: [String] = []
            for waiting in pending {
                guard waiting.connection == entry.connection, texts.count < Self.framesPerPass else { break }
                texts += waiting.frames.prefix(Self.framesPerPass - texts.count)
            }
            let snapshot = Snapshot(isFirst: !sentFirst, localAppToken: localAppToken, modeFields: modeFields,
                                    sessions: sessions, options: permissionOptions)
            let batch = await Self.analyze(texts, snapshot, socket: socket, ids: ids)
            if batch.firstSent {
                sentFirst = true
                localAppToken = nil
            }
            for outcome in batch.outcomes { complete(outcome) }
            switch batch.next {
            case nil:
                break
            case .spend(let ticket, let decision):
                // B2: a ticket in a refused frame is spent all the same.
                _ = gestures.redeem(ticket, connection: entry.connection, pick: nil)
                complete(Self.refuse(decision, socket: socket))
            case .decide(let facts, let box):
                complete(await decide(facts, box, connection: entry.connection, socket: socket, ids: ids))
            }
        }
        draining = false
    }

    /// The most frames one off-main pass takes (so a long line still yields between passes).
    static let framesPerPass = 256

    /// The next frame's result, to its send; a send whose frames are done (or stopped) is answered.
    private func complete(_ step: Step) {
        guard let entry = pending.first else { return }
        if !entry.frames.isEmpty { entry.frames.removeFirst() }
        switch step {
        case .sent: break
        case .refused(let error): entry.firstError = entry.firstError ?? error
        case .stop(let error):
            entry.firstError = entry.firstError ?? error
            entry.frames.removeAll()
        }
        if entry.frames.isEmpty { finishFirst() }
    }

    private func finishFirst() {
        let entry = pending.removeFirst()
        entry.reply(entry.firstError)
    }

    /// The main actor's part of one frame: small values only (the frame stays in its box).
    private func decide(_ facts: Facts, _ box: FrameBox, connection id: Int, socket: AcpmuxPaneSocket, ids: AcpmuxRequestIds) async -> Step {
        var rootRequested = false
        if facts.needsPathCheck {
            let scope = AcpmuxPathPolicy.Scope(roots: roots(), gestureRoots: gestureRoots(), fillCwd: primaryRoot(),
                                               agentHome: agentHome(), home: homeFolder, granted: addedRoots)
            let result = await Self.checkPaths(box, scope: scope)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            switch result {
            case .success(let gestureRootsUsed):
                // A folder of the new tab page's scan counts only when the user picked it.
                if !gestureRootsUsed.isEmpty {
                    guard gestures.consume() else {
                        return Self.refuse(.refuse(.pathOutsideRoots, method: facts.method, requestID: facts.pageID), socket: socket)
                    }
                    addedRoots += gestureRootsUsed.filter { !addedRoots.contains($0) }
                }
            case .failure(let refusal):
                if refusal.error == .pathOutsideRoots, let folder = refusal.outsidePath { rootRequested = offerRoot(folder) }
                return Self.refuse(.refuse(refusal.error, method: refusal.method, requestID: refusal.requestID), socket: socket,
                                   rootRequested: rootRequested)
            }
        }
        // The gesture rule: a ticket for its exact pick (R1: nothing else in `_meta`), else a live gesture.
        if !facts.isFirst {
            let granted: Bool
            if let ticket = facts.ticket {
                if facts.otherMeta {
                    _ = gestures.redeem(ticket, connection: id, pick: nil)
                    return Self.refuse(.refuse(.intentInvalid, method: facts.method, requestID: facts.pageID), socket: socket)
                }
                // B2: only set_mode, set_config_option and a prompt held for the trust answer (its
                // promptId) redeem a ticket, for their exact pick, into a session of this pane. A
                // ticket is spent even when it does not match.
                let redeemed = gestures.redeem(ticket, connection: id, pick: facts.pick)
                granted = redeemed && AgentPaneGestureIntent.methods[facts.method ?? ""] != nil
                    && facts.sessionId.map(sessions.contains) == true
            } else {
                granted = !facts.needsGesture || gestures.consume()
            }
            if !granted {
                Self.logger.info("agent pane transport gesture refused method=\(facts.method ?? "-", privacy: .public) \(self.gestures.debugDescription, privacy: .public)")
                return Self.refuse(.refuse(.gestureRequired, method: facts.method, requestID: facts.pageID), socket: socket)
            }
        }
        // R2 and P2: a mode, or a config option that is not free, needs the user's native
        // confirmation unless the daemon says that the value keeps the session asking.
        if let setting = facts.setting {
            let answer = await webModes(setting.sessionId, setting.configId, setting.value)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            let asks = answer?.freeConfigIds.contains(setting.configId) == true || answer?.asks == true
            if !asks {
                let confirmed = await confirm(setting.asked)
                guard id == current, self.socket === socket else { return .stop(.staleConnection) }
                if !confirmed { return Self.refuse(.refuse(.modeNotConfirmed, method: facts.method, requestID: facts.pageID), socket: socket) }
            }
        }
        // A folder harness: the user's Enable on the native sheet, then the prompt's sha256.
        if facts.harnessEnable {
            let confirmed = await confirmHarnessEnable(box)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            if !confirmed { return Self.refuse(.refuse(.harnessNotConfirmed, method: facts.method, requestID: facts.pageID), socket: socket) }
        }
        // The daemon sees only relay-owned ids; a page id is used by one request at a time.
        var relayID: Int?
        if let pageID = facts.pageID {
            guard let next = ids.begin(pageID: pageID, method: facts.method ?? "") else { return Self.refuseInFlight() }
            relayID = next
        }
        // A fork or handoff from a session outside the scope: the click's scope credit, used only
        // by a frame that goes out (every refusal above leaves it).
        if facts.foreignSource, !gestures.consumeScope() {
            if let relayID { ids.cancel(relayID) }
            Self.logger.info("agent pane transport scope refused method=\(facts.method ?? "-", privacy: .public) \(self.gestures.debugDescription, privacy: .public)")
            return Self.refuse(.refuse(.gestureRequired, method: facts.method, requestID: facts.pageID), socket: socket)
        }
        if facts.isFirst {
            sentFirst = true
            localAppToken = nil
        } else {
            noteSent(facts, relayID: relayID)
            // The switch's queued prompt goes out: the switch has ended, its tickets with it.
            if facts.method == "session/prompt" { gestures.clearTickets() }
        }
        if let error = await Self.encodeAndSend(box, relayID: relayID, socket: socket) {
            if let relayID { ids.cancel(relayID) }
            if error == .outboundOverflow { socket.close(code: 1008, reason: "outbound overflow", error: error) }
            return .stop(error)
        }
        return .sent
    }

    /// Asks the user to confirm a mode that does not ask (the native sheet); false without one.
    func confirm(_ asked: AgentPaneModeConfirmation) async -> Bool {
        guard let requestModeConfirmation else { return false }
        let gate = confirmationGate
        guard gate.open() else { return false }
        defer { gate.close() }
        return await withCheckedContinuation { continuation in
            requestModeConfirmation(asked) { continuation.resume(returning: $0) }
        }
    }

    /// Records what a sent frame starts, or opens by the user's gesture. An attach alone adds
    /// nothing: only an attach the user made (a click in the session list) brings a session in.
    /// An attach is not a grant: it uses the click's scope-add credit, one session per click, and
    /// leaves its grant credit for the prompt the same click sends. A fork or handoff from outside
    /// the scope used that credit in ``decide(_:_:connection:socket:ids:)``; its handoff is the pane's.
    func noteSent(_ facts: Facts, relayID: Int?) {
        if let session = facts.attachSession, !sessions.contains(session), gestures.consumeScope() {
            sessions.add(session)
        }
        if let method = facts.method {
            sessions.sent(method: method, id: facts.pageID, handoff: facts.handoffId, owned: facts.foreignSource)
        }
    }
}
