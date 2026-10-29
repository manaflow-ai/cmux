import AppKit

// Frame delivery (the `pageScriptFrames` feature): the router's envelopes reach
// the page as one script per frame, and a hidden page takes none until it shows.
extension PageWebView {
    /// From now on the router's envelopes wait for `frame` and go to the page as one script per
    /// frame, and while the view is hidden its events wait in the router by each stream's
    /// ``PageFrozenDelivery`` (the latest state per subscription, a bounded FIFO with a gap for a
    /// delta stream), sent as one batch in the turn it shows. Built-in commands, host calls and the
    /// view's own page scripts never wait a frame. ``WebUIHost/open(_:)`` calls it for every page it
    /// opens while the feature is on.
    package func deliverOnFrames(_ frame: PageScriptFrame) {
        let scripts = scripts
        scripts.deliverOnFrames(frame)
        router.deliverNow = { scripts.flush() }
        holdDeliveryWhileHidden(visible: engineVisible)
    }

    /// Whether the router delivers on frames (``deliverOnFrames(_:)``).
    package var deliversOnFrames: Bool { scripts.deliversOnFrames }

    /// Holds the router while the page is hidden and releases it when it shows, on frames only.
    /// Chrome throttles a hidden page's timers (third_party/blink/renderer/platform/scheduler/
    /// main_thread/page_scheduler_impl.cc) but still runs a WebUI's IPC; cmux holds the events too,
    /// because it keeps many page tabs, each with a stream (p13-webui.md, "Lifecycle").
    func holdDeliveryWhileHidden(visible: Bool) {
        guard scripts.deliversOnFrames else { return }
        if visible {
            router.releaseDelivery(.hidden)
        } else {
            router.holdDelivery(.hidden)
        }
    }
}
