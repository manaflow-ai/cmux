import AppKit

/// Where the input writer put a frame (task 092): the browser it went to and the input seq it
/// stamped in the frame's header (`Header::seq`), never 0.
struct ChromiumHostInputReceipt: Equatable, Sendable {
    var browser: Int32
    var seq: UInt32
}

/// The Command and Control key-downs a hosted page view sent (``ChromiumHostPageView``), by the
/// browser and input seq of the frame that carried each, until that browser reports the key
/// unhandled (KEY_UNHANDLED with the seq).
///
/// A report names its key exactly (the host's side, `CEFShim/src/host_key_seqs.h`, pairs it by the
/// event Chromium queued, as Chrome's ack carries the queued event back). A key the page handled is
/// never reported: it stays until ``limit`` drops the oldest.
struct ChromiumHostKeyDowns {
    /// Keys held at most (the host holds as many per page).
    static let limit = 64

    private var entries: [(browser: Int32, seq: UInt32, event: NSEvent)] = []

    /// Keys held now.
    var count: Int { entries.count }

    /// Holds `event`, sent to the page in the frame of `receipt`.
    mutating func record(_ event: NSEvent, _ receipt: ChromiumHostInputReceipt) {
        entries.append((receipt.browser, receipt.seq, event))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// The key-down `browser` got in the frame with input seq `seq`, while it is held; it is released.
    mutating func take(_ seq: UInt32, browser: Int32) -> NSEvent? {
        guard seq != 0, let index = entries.firstIndex(where: { $0.browser == browser && $0.seq == seq }) else { return nil }
        return entries.remove(at: index).event
    }

    /// The page view left its window or its page went away: no report can come for these keys.
    mutating func removeAll() {
        entries.removeAll()
    }
}
