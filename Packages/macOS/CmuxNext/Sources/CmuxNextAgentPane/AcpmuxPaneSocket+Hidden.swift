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
    /// end, a prompt queued or refused). List, presence and peer notices still go: they are few, and the page would
    /// read the whole list again for them.
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
