import CoreGraphics

/// The keyboard/scroll synchronization state machine, factored out of the view
/// controller as a pure value type so it unit-tests on the host (no UIKit, no
/// device, no display link, no keyboard).
///
/// The whole subsystem holds one invariant every frame: the inverted list's
/// bottom inset equals the overlap between the list's bottom edge and the
/// composer's top edge. The composer is the keyboard's `inputAccessoryView`, so
/// UIKit moves it for free; our only job is to keep the inset tracking it. The
/// hard part is that **two different clocks** can drive the composer:
///
/// - **Notifications** (`keyboardWillChangeFrame`) tell us a target ahead of
///   time with a duration and curve. They fire for show, programmatic hide, and
///   accessory (composer) resize.
/// - **The interactive dismiss drag** fires NO notification; the composer rides
///   the finger and then a release spring, so we sample its presentation layer
///   per frame with a `CADisplayLink`.
///
/// These must be mutually exclusive (one clock at a time) or they fight. That
/// mutual exclusion is the entire reason a state machine exists. The minimal set
/// of states is:
///
/// - ``KeyboardSyncState/idle``: no drag; notifications drive the inset.
/// - ``KeyboardSyncState/dragging``: finger down during an interactive dismiss;
///   the display link owns the inset; notifications are ignored.
/// - ``KeyboardSyncState/releasing``: finger lifted but the release spring is
///   still settling; still link-driven; notifications still ignored.
///
/// `releasing` is just `dragging` after the finger lifts; it is named separately
/// only because the settle detector runs there. `keyboardVisible` is an input
/// bit (set by show/hide), not a state.
public enum KeyboardSyncState: Equatable, Sendable {
    case idle
    case dragging
    case releasing
}

/// An event fed to the machine. Each maps to one concrete UIKit signal:
/// `beganDragging`/`endedDragging` to the scroll-view drag delegate,
/// `keyboardWill*` to the keyboard notifications, `linkTick` to the
/// `CADisplayLink`, `composerHeightChanged` to the growing text view, and
/// `tapToDismiss` to the tap-the-list gesture.
public enum KeyboardSyncEvent: Equatable, Sendable {
    case beganDragging
    /// Finger lifted. Sourced from `scrollViewDidEndDragging` REGARDLESS of
    /// `willDecelerate`: the touch ends here whether or not momentum follows.
    /// (The bug this fixes: gating on `!decelerate` left the finger "down"
    /// through a fling's deceleration, tying keyboard-settle to scroll-momentum.)
    case endedDragging
    case keyboardWillShow
    case keyboardWillHide
    /// The keyboard/accessory is animating to a new frame. `keyboardTop` is the
    /// frame's top edge in screen space.
    case keyboardFrameWillChange(keyboardTop: CGFloat)
    /// The composer's intrinsic height changed (text grew/shrank).
    case composerHeightChanged
    /// One display-link frame. `composerTop` is the composer's presentation-layer
    /// top in screen space; the machine uses it for settle detection.
    case linkTick(composerTop: CGFloat)
    /// The user tapped the list to dismiss the keyboard.
    case tapToDismiss
}

/// Where the inset target comes from when the machine asks for an animated
/// apply. The controller turns this into a concrete overlap using live geometry.
public enum KeyboardInsetTarget: Equatable, Sendable {
    /// Derive the overlap from this keyboard/accessory top (screen space).
    case keyboardTop(CGFloat)
    /// The composer is docked: use the resting overlap (bar height + safe area).
    case resting
}

/// A side effect the controller must perform. The machine never touches UIKit;
/// it only decides *what* should happen and lets the controller do it. Modeling
/// effects as data is what makes the transitions assertable in a host test.
public enum KeyboardSyncEffect: Equatable, Sendable {
    /// Start the per-frame display link (enter interactive tracking).
    case startLink
    /// Stop the display link (tracking finished).
    case stopLink
    /// Animate the inset to `target` using the triggering notification's
    /// duration/curve (or a short default for height changes).
    case applyAnimated(KeyboardInsetTarget)
    /// Write the inset unanimated from this per-frame composer top.
    case applyPerFrame(composerTop: CGFloat)
    /// Snap the inset to the true settled target after a release, absorbing the
    /// committed keyboard frame that was ignored while the link owned the inset.
    case reconcile
    /// The composer's accessory needs its intrinsic size invalidated.
    case invalidateComposerIntrinsicSize
    /// Resign the text view to lower the keyboard (tap-to-dismiss).
    case resignTextView
    /// Re-dock the accessory so the bar stays at the bottom after dismiss.
    case dockAccessory
    /// A keyboard frame notification arrived while the link owns the inset, so it
    /// must be dropped (the guard). Emitted for explicitness/testability; the
    /// controller does nothing.
    case ignoreKeyboardNotification
}

/// Pure reducer for the keyboard/scroll sync. Held by the controller as a
/// `var` and mutated on the main actor; value semantics keep it test-friendly.
public struct KeyboardSyncMachine: Sendable {
    public private(set) var state: KeyboardSyncState = .idle
    public private(set) var keyboardVisible = false

    private var settledFrames = 0
    private var lastComposerTop: CGFloat?
    private let settleEpsilon: CGFloat
    private let settleFrameThreshold: Int

    /// - Parameters:
    ///   - settleEpsilon: Per-frame composer movement below which a release is
    ///     considered stationary.
    ///   - settleFrameThreshold: Consecutive stationary frames that end a release.
    public init(settleEpsilon: CGFloat = 0.5, settleFrameThreshold: Int = 3) {
        self.settleEpsilon = settleEpsilon
        self.settleFrameThreshold = settleFrameThreshold
    }

    /// True while the display link owns the inset (`dragging` or `releasing`).
    /// This is exactly the window in which keyboard notifications are ignored.
    public var ownsInsetViaLink: Bool { state != .idle }

    public mutating func handle(_ event: KeyboardSyncEvent) -> [KeyboardSyncEffect] {
        switch event {
        case .keyboardWillShow:
            keyboardVisible = true
            return []
        case .keyboardWillHide:
            keyboardVisible = false
            return []
        case .beganDragging:
            return handleBegan()
        case .endedDragging:
            return handleEnded()
        case .keyboardFrameWillChange(let top):
            return handleFrameChange(top)
        case .composerHeightChanged:
            return handleHeightChange()
        case .linkTick(let top):
            return handleTick(top)
        case .tapToDismiss:
            return keyboardVisible ? [.resignTextView, .dockAccessory] : []
        }
    }

    private mutating func handleBegan() -> [KeyboardSyncEffect] {
        switch state {
        case .idle:
            // Only an interactive dismiss is possible while the keyboard is up.
            // With it down, a drag is a plain history scroll: stay idle, no link.
            guard keyboardVisible else { return [] }
            state = .dragging
            settledFrames = 0
            lastComposerTop = nil
            return [.startLink]
        case .releasing:
            // Re-grab mid-spring: the link is already live, just go back to
            // finger-down so the settle detector stops.
            state = .dragging
            settledFrames = 0
            return []
        case .dragging:
            return []
        }
    }

    private mutating func handleEnded() -> [KeyboardSyncEffect] {
        // Finger up. Only meaningful mid-drag; otherwise (idle history scroll, or
        // an already-released spring) it is a no-op.
        guard state == .dragging else { return [] }
        state = .releasing
        settledFrames = 0
        return []
    }

    private func handleFrameChange(_ top: CGFloat) -> [KeyboardSyncEffect] {
        switch state {
        case .idle:
            return [.applyAnimated(.keyboardTop(top))]
        case .dragging, .releasing:
            // The link owns the inset; a competing animation here would fight it.
            return [.ignoreKeyboardNotification]
        }
    }

    private func handleHeightChange() -> [KeyboardSyncEffect] {
        var effects: [KeyboardSyncEffect] = [.invalidateComposerIntrinsicSize]
        // The inset only needs an explicit apply when the keyboard is DOWN and we
        // are idle: the docked bar grew, so the resting overlap grew. When the
        // keyboard is UP, resizing the accessory fires its own
        // `keyboardWillChangeFrame` that owns the inset (with the real curve), so
        // applying here too would double up with a conflicting target. When the
        // link owns the inset (dragging/releasing), it covers the change.
        if state == .idle, !keyboardVisible {
            effects.append(.applyAnimated(.resting))
        }
        return effects
    }

    private mutating func handleTick(_ top: CGFloat) -> [KeyboardSyncEffect] {
        switch state {
        case .idle:
            // The link should not be running here; ignore a stray late tick.
            return []
        case .dragging:
            // Finger down: glue the inset, never settle (the keyboard may be
            // parked under a held finger).
            lastComposerTop = top
            return [.applyPerFrame(composerTop: top)]
        case .releasing:
            defer { lastComposerTop = top }
            if let last = lastComposerTop, abs(top - last) < settleEpsilon {
                settledFrames += 1
                if settledFrames >= settleFrameThreshold {
                    state = .idle
                    settledFrames = 0
                    return [.stopLink, .reconcile]
                }
                return [.applyPerFrame(composerTop: top)]
            }
            settledFrames = 0
            return [.applyPerFrame(composerTop: top)]
        }
    }
}
