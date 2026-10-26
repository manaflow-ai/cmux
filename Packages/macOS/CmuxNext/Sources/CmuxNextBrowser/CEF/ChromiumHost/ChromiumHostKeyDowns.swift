import AppKit

/// The key-downs a hosted page has (``ChromiumHostPageView``), by the key seq of the frame that
/// carried each, until the page handled the key or the host reported it unhandled
/// (KEY_UNHANDLED with that seq, p01-process-030).
///
/// A widget acks its key events in the order it got them
/// (`content/browser/renderer_host/render_widget_host_impl.cc`, the key event queue), and only
/// an unhandled key is reported, so a report releases its key and every older one: the keys the
/// page handled. The host's side is `CEFShim/src/host_key_seqs.h`. Bounded: a host that never
/// reports drops the oldest.
struct ChromiumHostKeyDowns {
    /// Keys held at most (the host holds as many per page).
    static let limit = 64

    private var entries: [(seq: Int32, event: NSEvent)] = []
    private var lastSeq: Int32 = 0

    /// Keys held now.
    var count: Int { entries.count }

    /// Holds `event` and returns the key seq its frame carries: 1 ... `Int32.max`, never 0
    /// (0 is "no seq" in KEY_UNHANDLED's request).
    mutating func record(_ event: NSEvent) -> Int32 {
        lastSeq = lastSeq == .max ? 1 : lastSeq + 1
        entries.append((lastSeq, event))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        return lastSeq
    }

    /// The key-down whose frame carried `seq`, while it is held; it and every older one are released.
    mutating func take(_ seq: Int32) -> NSEvent? {
        guard seq != 0, let index = entries.firstIndex(where: { $0.seq == seq }) else { return nil }
        let event = entries[index].event
        entries.removeFirst(index + 1)
        return event
    }

    /// The page view left its window or its page went away: no report can come for these keys.
    mutating func removeAll() {
        entries.removeAll()
    }
}
