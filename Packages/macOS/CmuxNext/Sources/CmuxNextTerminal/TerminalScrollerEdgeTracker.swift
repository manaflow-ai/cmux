import AppKit

/// Tells a ``TerminalHostView`` with scrollback but no scroller built yet where the pointer is over
/// it, so the pointer at the trailing edge builds and reveals the scroller (Lawrence 2026-11-12, msg
/// 30795: "moving mouse close over the scrollbar should make it appear; should not change anything
/// about the idle state"). One tracking area, pointer events only: nothing runs on a key press. The
/// host drops it once the scroller is built, whose own tracking area takes over.
@MainActor
final class TerminalScrollerEdgeTracker: NSResponder {
    private weak var host: TerminalHostView?
    private var area: NSTrackingArea?

    init(host: TerminalHostView) {
        self.host = host
        super.init()
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        host.addTrackingArea(area)
        self.area = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Removes the tracking area (the scroller is built, or the host goes away).
    func detach() {
        if let area { host?.removeTrackingArea(area) }
        area = nil
    }

    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { host?.pointerMoved(to: nil) }

    private func report(_ event: NSEvent) {
        guard let host else { return }
        host.pointerMoved(to: host.convert(event.locationInWindow, from: nil))
    }
}
