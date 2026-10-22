import AppKit
import CmuxNextWakeups

/// Runs ``SidebarRailPeek`` for a container: feeds it the pointer (a tracking view over the
/// container, which is the rail's width while closed and the sidebar's while open) and its two
/// one-shot timers, and reports the open state. No polling: a timer exists only between a pointer
/// event and its deadline.
@MainActor
final class SidebarRailPeekDriver {
    /// The pointer must rest on the rail this long before the sidebar opens.
    static let dwell: Duration = .milliseconds(150)
    /// The open sidebar closes this long after the pointer left it.
    static let grace: Duration = .milliseconds(350)

    private(set) var state = SidebarRailPeek()
    /// Called when the open state changes.
    var onChange: ((Bool) -> Void)?
    /// Whether the person is busy in the sidebar now (a drag, a menu, a rename field).
    var isBusy: () -> Bool = { false }
    private let dwellTimer = DemandTimer(owner: "sidebar.rail.dwell")
    private let graceTimer = DemandTimer(owner: "sidebar.rail.grace")
    let tracker = SidebarRailTrackingView()

    init() {
        tracker.onHoverChange = { [weak self] inside in self?.send(inside ? .pointerEnteredSidebar : .pointerExited) }
    }

    func send(_ event: SidebarRailPeek.Event) {
        let wasOpen = state.isOpen
        switch state.handle(event) {
        case .none: break
        case .startDwell:
            dwellTimer.schedule(after: Self.dwell) { @MainActor [weak self] in self?.send(.dwellElapsed) }
        case .startGrace:
            graceTimer.schedule(after: Self.grace) { @MainActor [weak self] in
                guard let self else { return }
                self.send(.graceElapsed(busy: self.isBusy()))
            }
        case .cancelTimers:
            dwellTimer.cancel()
            graceTimer.cancel()
        }
        if state.isOpen != wasOpen { onChange?(state.isOpen) }
    }
}

/// A view over the container that only tracks the pointer: it takes no clicks (`hitTest` is nil),
/// so rows, the rail and the resize handle under it work as before.
final class SidebarRailTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next)
        area = next
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
