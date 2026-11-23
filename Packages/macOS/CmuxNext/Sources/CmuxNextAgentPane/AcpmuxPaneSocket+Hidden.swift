import Foundation

/// A pane nobody can see gets none of its chat's stream (2026-11-21, Leo's NIGHTLY: 214 chat tabs, a few of them
/// streaming, the main thread busy pushing their records into pages nobody saw). The pacer only held a hidden
/// pane's records until a turn's end or a full flush, and then sent them all: every record still crossed the main
/// thread once (Chromium parses each push's JSON there), so a hidden chat cost what a shown one does. Now the socket
/// leaves the stream out while the pane is hidden (``AcpmuxPaneShedding/sheddableWhileHidden(_:method:)``), and when
/// it shows the page gets one `_acpmux/lagged` and reads what it missed from where its chat stopped being whole
/// (direct.ts `resyncAfterLag`, reason `host_hidden`). Replies, requests, permissions, a prompt's acceptance and a
/// turn's boundaries (``pageWaits(on:)``) still go, so a hidden page never waits on something it asked for.
extension AcpmuxPaneSocket {
    /// Nobody sees the page, or it is frozen (true), or it shows again (false): ``AgentPaneTransport/pageSight``
    /// and ``AgentPaneTransport/beforePageWork``.
    ///
    /// While it sleeps, the local daemon's list notices (``AcpmuxPaneShedding/listNotices``: every chat's
    /// row change, about 4.5 a second and up to 80 KB each on Leo's Mac, 184 KB/s a page) are left out
    /// instead of queued, except a change of the pane's own chat (``AcpmuxPaneSessions/named(in:)``).
    /// Queued, they reached the hidden page anyway: 4 MB of them is a backlog (``pageWaits``), which
    /// a hidden page gets, so every hidden chat page parsed and folded 4 MB of other chats' rows about
    /// every 22 s on the renderer's one JavaScript thread, and a frozen one thawed for it and stayed
    /// awake 30 s (`browser.freezeHiddenTabs`). When it shows it gets one `_acpmux/lagged`
    /// (``AcpmuxPaneShedding/wakeMarker(dropped:)``) and reads the rows changed since its list cursor
    /// (direct.ts `resyncAfterLag`, `SessionPager.first`). Its own chat's stream, replies, requests
    /// and observed notices are never left out. A remote wire's page keeps its notices.
    nonisolated func setAsleep(_ asleep: Bool) {
        let woke = withState { state -> Bool in
            guard state.asleep != asleep else { return false }
            state.asleep = asleep
            return !asleep && state.sparedAsleep > 0 && state.closed == nil
        }
        guard woke else { return }
        // After the pass over frames that came before the wake, as a shed episode's end is.
        onInbound { [self] in
            let spared = withState { state -> Int in
                // Asleep again before this ran: the count waits for the next wake.
                guard !state.asleep else { return 0 }
                defer { state.sparedAsleep = 0 }
                return state.sparedAsleep
            }
            guard spared > 0 else { return }
            AgentPaneTransport.logger.debug("agent pane transport woke page spared=\(spared, privacy: .public) connection=\(self.connection, privacy: .public)")
            enqueueForPage([AcpmuxPaneShedding.wakeMarker(dropped: spared)], awaited: 1)
        }
    }

    /// List notices left out while the page slept, not yet told to it (tests).
    nonisolated var sparedWhileAsleep: Int { withState { $0.sparedAsleep } }

    /// Whether nobody can see the pane. Shown again, a shed episode ends on the inbound queue, after the pass
    /// over the frames that came before it, so the end marker follows everything the page got meanwhile.
    nonisolated func setHidden(_ hidden: Bool) {
        let end = withState { state -> Bool in
            state.hidden = hidden
            guard !hidden, state.closed == nil, state.hiddenShed != nil, !state.hiddenShedEnding else { return false }
            state.hiddenShedEnding = true
            return true
        }
        if end { onInbound { [self] in endHiddenShedding() } }
    }

    private nonisolated func endHiddenShedding() {
        let dropped = withState { state -> Int? in
            state.hiddenShedEnding = false
            // Hidden again before this ran: the episode goes on, and ends at the next show.
            guard state.closed == nil, !state.hidden, let shed = state.hiddenShed else { return nil }
            state.hiddenShed = nil
            return shed
        }
        guard let dropped else { return }
        // Awaited: the page reads what it missed now that it shows.
        enqueueForPage([AcpmuxPaneShedding.hiddenEndMarker(dropped: dropped)], awaited: 1)
    }

    /// Stream records left out of the current hidden episode; nil while none is (tests, `debug.agent_pane`).
    nonisolated var hiddenShedCount: Int? { withState { $0.hiddenShed } }
}

extension AcpmuxPaneShedding {
    /// The records of a chat's stream: a pane nobody sees reads them again when it shows.
    nonisolated static let streamMethods: Set<String> = ["session/update", "_acpmux/event"]

    /// Whether a pane nobody can see may go without `text` until it shows: a stream record the page can read again
    /// (``sheddable(_:method:)`` already holds) that it does not wait on (``AcpmuxPaneSocket/pageWaits(on:)``: a turn's
    /// end, a prompt queued or refused). Other chats' list notices go by ``AcpmuxPaneSocket/setAsleep(_:)``.
    nonisolated static func sheddableWhileHidden(_ text: String, method: String?) -> Bool {
        guard let method, streamMethods.contains(method) else { return false }
        return !AcpmuxPaneSocket.pageWaits(on: text)
    }

    /// Where a hidden episode starts, in the place of the first record left out: the page notes the seq its chat is
    /// whole through, since the turn boundaries it still gets move its cursor past the hole.
    nonisolated static let hiddenStartMarker =
        #"{"jsonrpc":"2.0","method":"_acpmux/lagged","params":{"dropped":0,"reason":"host_hidden","phase":"start"}}"#

    /// A hidden episode's end, once the pane shows: the page reads its chat from the start marker's seq.
    nonisolated static func hiddenEndMarker(dropped: Int) -> String {
        #"{"jsonrpc":"2.0","method":"_acpmux/lagged","params":{"dropped":\#(dropped),"reason":"host_hidden"}}"#
    }
}
