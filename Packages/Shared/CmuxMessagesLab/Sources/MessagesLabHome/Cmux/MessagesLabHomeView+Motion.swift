import AppKit
import os

/// cmux (cx-sya4n: blinking lights give a teammate headaches; nothing loops under Reduce
/// Motion): the vendored transcript's caret and typing row read this.
extension MessagesLabHomeView {
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
    nonisolated public static let reduceMotionDidChange = Notification.Name("MessagesLabHome.reduceMotionDidChange")

    /// Reduce Motion: the caret holds solid, the typing dots stand still and do not breathe.
    nonisolated static var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Follows the system setting and the pin: loops already running stop or start again. Runs at
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

    /// Stills (or restarts) the caret blink and every typing row under this view.
    func applyReduceMotion() {
        var views: [NSView] = [self]
        while let view = views.popLast() {
            if let field = view as? FieldTextView { field.applyReduceMotion() }
            views += view.subviews
        }
        var layers: [CALayer] = layer.map { [$0] } ?? []
        while let layer = layers.popLast() {
            if let cell = layer.delegate as? RowCell { cell.applyReduceMotion() }
            layers += layer.sublayers ?? []
        }
    }
}

extension FieldTextView {
    /// The blink stops under Reduce Motion and starts again after it, while the caret shows.
    func applyReduceMotion() {
        let state = caretState
        if MessagesLabHomeView.reducesMotion {
            caretLayer.removeAnimation(forKey: "blink")
            caretLayer.opacity = 1
        } else if state.shown, !state.blinks {
            startBlink()
        }
    }
}

extension MessagesLabHomeView {
    /// Whether the typing indicator holds still: Reduce Motion, or the host's Home motion gate
    /// (`voiceMotionGate`: the app's animation switch) is off. Off the main thread it holds still.
    nonisolated static var holdsTypingStill: Bool {
        reducesMotion || !HomeTypingMotionGate.allowsLoops()
    }
}

extension RowCell {
    /// A typing row's dots stand still and its breath stops under Reduce Motion or with Home
    /// animations off; after either they run again from now. The status line's shimmer follows.
    func applyReduceMotion() {
        // The status line's shimmer stops or sweeps again (HomeNoticeShimmer).
        if let shimmer = noticeShimmer, bitmap.mask === shimmer.mask { shimmer.refresh() }
        guard dots.contains(where: { $0.sublayers?.first?.animation(forKey: "dots") != nil }) else { return }
        let now = CACurrentMediaTime()
        startTypingDots(begin: now)
        startTypingBreath(insert: now)
    }
}
