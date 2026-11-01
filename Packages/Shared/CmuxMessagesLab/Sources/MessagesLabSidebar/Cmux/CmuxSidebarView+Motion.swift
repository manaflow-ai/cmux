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

    /// The host's gate for a Chief's avatar loop (cmux-next: `Motion.home.animatesLoops`, so calm
    /// mode, the animation speed `off` and Home's motion switch also apply); nil: only Reduce Motion
    /// decides. A change applies when `reduceMotionDidChange` posts.
    public var avatarLoopGate: (@MainActor () -> Bool)? {
        get { controller.avatarMotion.gate }
        set { controller.avatarMotion.gate = newValue }
    }

    /// How a Chief's avatar moves (the host's Debug setting); a change restyles every avatar at once.
    public var avatarMotionStyle: CmuxSidebarAvatarMotionStyle {
        get { controller.avatarMotion.style }
        set {
            guard newValue != controller.avatarMotion.style else { return }
            controller.avatarMotion.style = newValue
            controller.refreshAvatarMotion()
        }
    }

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
        return [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil, using: apply),
            NotificationCenter.default.addObserver(forName: Self.reduceMotionDidChange, object: nil, queue: nil, using: apply),
        ]
    }

    /// Stills (or restarts) every typing bubble and Chief avatar loop in the list.
    func applyReduceMotion() {
        var layers: [CALayer] = layer.map { [$0] } ?? []
        while let layer = layers.popLast() {
            if let bubble = layer as? SidebarTypingLayer { bubble.animate() }
            layers += layer.sublayers ?? []
        }
        // From the controller's own rows and tiles: this view's `layer` is nil until an ancestor
        // makes it layer-backed, so the walk above may not reach them.
        controller.refreshAvatarMotion()
    }
}
