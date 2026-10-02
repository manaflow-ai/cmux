import AppKit
import CmuxNextDesign

extension TranscriptView {
    /// Applies one source change: window, rows, then the motion it causes.
    func handle(_ change: HomeTranscriptChange) {
        let oldKeys = Set(rowLayout.rows.suffix(Self.tailRows).map(\.key))
        var sent: String?
        var received = Set<String>()
        var windowChange = WindowChange.none
        let ctx = context()
        switch change {
        case .appended(let messages):
            measurer.measure(messages, geometry: geometry)
            windowChange = history.appendConfirmed(messages)
            received = Set(messages.filter { $0.authorID != meID }.map(\.rowKey))
        case .updated(let message):
            measurer.measure([message], geometry: geometry)
            windowChange = history.update(message)
        case .pendingAdded(let message):
            measurer.measure([message], geometry: geometry)
            windowChange = history.addPending(message)
            if message.authorID == meID { sent = message.rowKey }
        case .pendingResolved(let clientMsgID, let confirmed):
            measurer.measure([confirmed], geometry: geometry)
            windowChange = history.resolvePending(clientMsgID: clientMsgID, confirmed: confirmed)
        case .pendingFailed(let clientMsgID, let reason):
            windowChange = history.failPending(clientMsgID: clientMsgID, reason: reason)
        case .typing(let ids):
            typingIDs = ids
            onTypingChange?(ids)
            _ = rowLayout.setTyping(history, context: context())
        case .readThrough(let seq):
            readThrough = seq
            _ = rowLayout.refreshReceipts(history, context: context())
        case .reset:
            reload()
            return
        }
        _ = ctx
        applyToRows(windowChange)
        planMotion(oldKeys: oldKeys, sent: sent, received: received)
        render()
    }

    /// Rows near the newest end that the motion diff compares.
    static var tailRows: Int { 60 }

    /// The motion of new rows (MessagesLab `Scene.diff`): the sent text flies
    /// from the composer, received rows fade in, every row that moved follows
    /// with the event's timing. Reduce Motion: new rows cross-fade, nothing moves.
    private func planMotion(oldKeys: Set<String>, sent: String?, received: Set<String>) {
        guard anchor.pinned else { return }
        let t = CACurrentMediaTime()
        let added = rowLayout.rows.suffix(Self.tailRows).filter { !oldKeys.contains($0.key) }
        guard Motion.animatesMovement else {
            flightGhost = nil
            guard Motion.animatesFades else { return }
            let fade = TranscriptTiming.fadeIn(Motion.duration(.crossfade))
            for row in added { rowFade[row.key, default: []].append(committer.make(start: t, delta: -1, timing: fade)) }
            return
        }
        var timing = TranscriptTiming.grow
        var rank = 0
        func use(_ r: Int, _ value: TranscriptTiming) { if r > rank { rank = r; timing = value } }
        let firstSentPart = sent.map { "\($0)#0" }
        for row in added {
            if case .typing = row.kind {
                use(4, .received)
                rowFade[row.key, default: []].append(committer.make(start: t, delta: -1, timing: .fadeIn(0.2)))
            } else if let key = row.messageKey, received.contains(key), row.isBubbleLike {
                use(5, .received)
                rowFade[row.key, default: []].append(committer.make(start: t + 0.243, delta: -1, timing: .fadeIn(0.306)))
            } else if let key = row.messageKey, key == sent {
                use(6, .sendScroll)
                if row.key == firstSentPart, let ghost = flightGhost, t - ghost.time < 1 {
                    // the row stays hidden while its bubble flies in from the composer
                    rowFade[row.key, default: []].append(committer.make(
                        start: t, delta: -1, timing: .hold(duration: TranscriptTiming.flightDuration)))
                    pendingFlights[row.key] = (ghost.rect, t)
                    flightGhost = nil
                } else if case .label = row.kind {
                    rowFade[row.key, default: []].append(committer.make(start: t + 0.087, delta: -1, timing: .fadeIn(0.14)))
                }
            } else if case .label = row.kind {
                use(3, .receiptChange)
                rowFade[row.key, default: []].append(committer.make(start: t + 0.087, delta: -1, timing: .fadeIn(0.14)))
            } else {
                use(1, .grow)
            }
        }
        if added.isEmpty { use(2, .receiptChange) }
        pendingEvent = (t, timing)
    }

    /// The composer is about to send `text` from `rect` (this view's y-down
    /// points): the next pending row of mine flies from there.
    func prepareSendFlight(from rect: CGRect, text: String) {
        flightGhost = (rect, text, CACurrentMediaTime())
    }

    /// Starts flights for rows that were just placed, and advances running ones.
    func renderFlights(targets: [String: CGRect], now t: Double) {
        for (key, pending) in pendingFlights {
            pendingFlights[key] = nil
            guard let slot = targets[key], let row = live[key]?.row,
                  case .bubble(_, let text, let mentions, _, _, _, false) = row.kind else { continue }
            let flight = SendFlight(start: pending.time, ghost: pending.ghost, slot: slot, committer: committer)
            flight.makeLayers(text: text, mentions: mentions, geometry: geometry, colors: colors, scale: scale)
            layer?.addSublayer(flight.container)
            flights[key] = flight
        }
        for (key, flight) in flights {
            if t > flight.end {
                flight.container.removeFromSuperlayer()
                flights[key] = nil
                continue
            }
            flight.render(now: t, viewHeight: bounds.height, viewWidth: bounds.width)
        }
    }
}
