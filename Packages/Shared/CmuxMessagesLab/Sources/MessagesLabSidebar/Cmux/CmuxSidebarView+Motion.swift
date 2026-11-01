import AppKit
import os

/// cmux (cx-sya4n: blinking lights give a teammate headaches; nothing loops under Reduce
/// Motion): the vendored list's typing bubble reads this.
extension CmuxSidebarView {
    /// The host's Reduce Motion pin (cmux-next mirrors `Motion.reduceMotionOverride`, the
    /// tests' pin); nil reads the system setting. A change posts `reduceMotionDidChange`.
    nonisolated public static var reduceMotionOverride: Bool? {
        get { reduceMotionPin.withLock { $0 } }
        set {
            let changed = reduceMotionPin.withLock { pin in
                defer { pin = newValue }
                return pin != newValue
            }
            if changed { NotificationCenter.default.post(name: reduceMotionDidChange, object: nil) }
        }
    }
    nonisolated private static let reduceMotionPin = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Posted when `reduceMotionOverride` changes.
    nonisolated public static let reduceMotionDidChange = Notification.Name("MessagesLabSidebar.reduceMotionDidChange")

    /// Reduce Motion: the typing bubble's dots stand still.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The host's motion gate for movement (cmux-next: `Motion.animatesMovement`, so the
    /// animation speed `off` and the motion settings also apply); nil: only Reduce Motion
    /// decides. Read when a movement starts.
    public static var movementGate: (@MainActor () -> Bool)?

    /// Movement (the pin drag's lift, slides and landing) animates: not Reduce Motion, and the
    /// host's gate allows it. When false the change applies in one frame.
    static var animatesMovement: Bool { !reducesMotion && (movementGate?() ?? true) }

    /// The host's gate for loops (cmux-next: `Motion.home.animatesLoops`, so calm mode, the speed
    /// `off` and Home's motion switch also stop them); nil: only Reduce Motion decides. A Chief's
    /// avatar loop (``SidebarAvatarMotion``) runs only while it allows.
    public static var avatarLoopGate: (@MainActor () -> Bool)?

    /// How a Chief's avatar moves (the host's Debug setting); a change applies on the next `show`.
    public static var avatarMotionStyle = CmuxSidebarAvatarMotionStyle.float

    /// Follows the system setting and the pin: bubbles already pulsing stop or start again. Runs at
    /// once on the main thread (a test's pin change applies before it returns), else on the main
    /// queue's next turn.
    func observeReduceMotion() -> [any NSObjectProtocol] {
        let apply: @Sendable (Notification) -> Void = { [weak self] _ in
            if Thread.isMainThread {
                // main-proof: guarded by Thread.isMainThread above
                MainActor.assumeIsolated { self?.applyReduceMotion() }
            } else {
                // main-proof: DispatchQueue.main runs its blocks on the main thread
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyReduceMotion() } }
            }
        }
        // An avatar's loop also stops while the app is inactive and while a window is covered or
        // hidden, and starts again when it shows (SidebarAvatarMotion's stop conditions).
        let center = NotificationCenter.default
        return [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil, using: apply),
            center.addObserver(forName: Self.reduceMotionDidChange, object: nil, queue: nil, using: apply),
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil, using: apply),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil, using: apply),
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil, using: apply),
        ]
    }

    /// Stills (or restarts) every typing bubble and Chief avatar loop in the list.
    func applyReduceMotion() {
        var layers: [CALayer] = layer.map { [$0] } ?? []
        while let layer = layers.popLast() {
            if let bubble = layer as? SidebarTypingLayer { bubble.animate() }
            if let row = layer as? SidebarRowLayer { SidebarAvatarMotion.refresh(row.avatar, window: window) }
            layers += layer.sublayers ?? []
        }
    }
}
