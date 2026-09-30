public import AppKit
public import CmuxNextWakeups

/// Ends a hover card that an action opened (palette, context menu) rather
/// than the pointer: the next key press, click or scroll in the app, or a
/// one-shot deadline, whichever comes first. The monitor and the deadline
/// exist only while such a card is shown.
@MainActor
public final class PinnedCardDismissal {
    public let lifetime: Duration
    private let timer: DemandTimer
    private var monitor: Any?
    private var onDismiss: (@MainActor () -> Void)?

    public init(lifetime: Duration = .seconds(10), timer: DemandTimer = DemandTimer(owner: "Resources.pinnedCard")) {
        self.lifetime = lifetime
        self.timer = timer
    }

    public var isArmed: Bool { onDismiss != nil }

    /// Arms the dismissal; `onDismiss` runs once.
    public func arm(_ onDismiss: @escaping @MainActor () -> Void) {
        disarm()
        self.onDismiss = onDismiss
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.fire()
            return event
        }
        timer.schedule(after: lifetime) { @MainActor [weak self] in self?.fire() }
    }

    /// Drops the monitor and the deadline without calling back.
    public func disarm() {
        timer.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onDismiss = nil
    }

    private func fire() {
        let callback = onDismiss
        disarm()
        callback?()
    }
}
