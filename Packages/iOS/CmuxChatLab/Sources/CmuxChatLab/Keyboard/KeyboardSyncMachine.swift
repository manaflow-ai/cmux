import CoreGraphics

/// The keyboard/scroll synchronization state machine, factored out of the view
/// controller as a pure value type so it unit-tests on the host (no UIKit, no
/// device, no display link, no keyboard).
///
/// The whole subsystem holds one invariant: the inverted list's bottom inset
/// equals the overlap between the list's bottom edge and the composer's top
/// edge. The composer is the keyboard's `inputAccessoryView`, so UIKit moves it
/// for free; our only job is to keep the inset tracking it. The inset has
/// exactly one owner at a time, and which owner depends on a single question:
/// **is the keyboard actually moving?**
///
/// - It is NOT moving during plain content scrolling (keyboard closed, or
///   keyboard open and the user scrolls the history). Then nobody writes the
///   inset; the scroll view's pan owns the offset.
/// - It IS moving during an interactive dismiss drag and its release spring.
///   Then a `CADisplayLink` owns the inset, sampling the composer's presentation
///   layer each frame (the keyboard frame notifications do not fire during the
///   drag).
///
/// The states:
///
/// - ``KeyboardSyncState/idle``: no finger; notifications own the inset.
/// - ``KeyboardSyncState/scrolling``: finger down, keyboard not moving. Inset
///   frozen. When the keyboard is open a read-only display-link *observer* runs
///   to detect the moment an interactive dismiss engages; it writes nothing.
/// - ``KeyboardSyncState/dismissing``: the keyboard is riding the finger down.
///   The link writes the inset every frame; notifications are ignored.
/// - ``KeyboardSyncState/releasing``: finger up; the link rides the release
///   spring and settles, then reconciles.
///
/// The crucial correction over a naive model: a keyboard-open scroll-up is
/// `scrolling`, NOT a dismiss. Writing the inset every frame during such a
/// scroll (the old behavior) hammered `contentInset` against the user's own pan.
public enum KeyboardSyncState: Equatable, Sendable {
    case idle
    case scrolling
    case dismissing
    case releasing
}

/// An event fed to the machine, each mapping to one concrete UIKit signal.
public enum KeyboardSyncEvent: Equatable, Sendable {
    /// The user began a drag. `keyboardOpen` (derived by the controller from the
    /// keyboard frame, not from will-show/hide) decides whether an interactive
    /// dismiss is even possible, i.e. whether the observer link should run.
    case beganDragging(keyboardOpen: Bool)
    /// Finger lifted. Sourced from `scrollViewDidEndDragging` REGARDLESS of
    /// `willDecelerate`: the touch ends here whether or not momentum follows.
    case endedDragging
    /// The keyboard/accessory is animating to a new frame (`keyboardTop` is its
    /// top edge in screen space).
    case keyboardFrameWillChange(keyboardTop: CGFloat)
    /// The composer's intrinsic height changed. `keyboardOpen` decides whether
    /// the docked resting inset needs an explicit re-apply.
    case composerHeightChanged(keyboardOpen: Bool)
    /// One display-link frame. `composerTop` is the composer's presentation-layer
    /// top in screen space.
    case linkTick(composerTop: CGFloat)
    /// The user tapped the list to dismiss the keyboard (controller only sends
    /// this while the field is first responder).
    case tapToDismiss
}

/// Where an animated inset apply should target.
public enum KeyboardInsetTarget: Equatable, Sendable {
    case keyboardTop(CGFloat)
    case resting
}

/// A side effect the controller performs. Modeling effects as data is what makes
/// the transitions assertable in a host test.
public enum KeyboardSyncEffect: Equatable, Sendable {
    /// Start the display link. In `scrolling` it runs read-only (observer); in
    /// `dismissing`/`releasing` it writes the inset.
    case startLink
    case stopLink
    case applyAnimated(KeyboardInsetTarget)
    case applyPerFrame(composerTop: CGFloat)
    /// Snap to the settled target after a release, absorbing the committed
    /// keyboard frame that was ignored while the link owned the inset.
    case reconcile
    case invalidateComposerIntrinsicSize
    case resignTextView
    case dockAccessory
    case ignoreKeyboardNotification
}

/// Pure reducer for the keyboard/scroll sync.
public struct KeyboardSyncMachine: Sendable {
    public private(set) var state: KeyboardSyncState = .idle

    /// True while the display link is running (observer or writer).
    private var linkActive = false
    /// The composer's top at the start of an observed scroll; movement beyond
    /// `engageThreshold` from it means the interactive dismiss has engaged.
    private var engageBaseline: CGFloat?
    private var settledFrames = 0
    private var lastComposerTop: CGFloat?

    private let engageThreshold: CGFloat
    private let settleEpsilon: CGFloat
    private let settleFrameThreshold: Int

    /// - Parameters:
    ///   - engageThreshold: How far the composer must move from its scroll-start
    ///     position before we treat the gesture as a dismiss (not a scroll).
    ///   - settleEpsilon: Per-frame composer movement below which a release is
    ///     considered stationary.
    ///   - settleFrameThreshold: Consecutive stationary frames that end a release.
    public init(engageThreshold: CGFloat = 4, settleEpsilon: CGFloat = 0.5, settleFrameThreshold: Int = 3) {
        self.engageThreshold = engageThreshold
        self.settleEpsilon = settleEpsilon
        self.settleFrameThreshold = settleFrameThreshold
    }

    /// True while the display link owns (writes) the inset.
    public var ownsInsetViaLink: Bool { state == .dismissing || state == .releasing }

    public mutating func handle(_ event: KeyboardSyncEvent) -> [KeyboardSyncEffect] {
        switch event {
        case .beganDragging(let keyboardOpen):
            return handleBegan(keyboardOpen: keyboardOpen)
        case .endedDragging:
            return handleEnded()
        case .keyboardFrameWillChange(let top):
            return handleFrameChange(top)
        case .composerHeightChanged(let keyboardOpen):
            return handleHeightChange(keyboardOpen: keyboardOpen)
        case .linkTick(let top):
            return handleTick(top)
        case .tapToDismiss:
            return [.resignTextView, .dockAccessory]
        }
    }

    private mutating func handleBegan(keyboardOpen: Bool) -> [KeyboardSyncEffect] {
        switch state {
        case .idle:
            state = .scrolling
            engageBaseline = nil
            settledFrames = 0
            lastComposerTop = nil
            // Only a keyboard that is up can be dismissed, so only then do we run
            // the observer to watch for the dismiss engaging. Keyboard closed: a
            // drag is a plain history scroll, no link at all.
            if keyboardOpen {
                linkActive = true
                return [.startLink]
            }
            return []
        case .releasing:
            // Re-grab mid-spring: the keyboard is still moving, so go back to
            // dismissing. The link is already live.
            state = .dismissing
            settledFrames = 0
            return []
        case .scrolling, .dismissing:
            return []
        }
    }

    private mutating func handleEnded() -> [KeyboardSyncEffect] {
        switch state {
        case .scrolling:
            // The dismiss never engaged: it was a plain scroll. Tear down the
            // observer (if any) and return to idle. The inset was never touched.
            let effects: [KeyboardSyncEffect] = linkActive ? [.stopLink] : []
            state = .idle
            linkActive = false
            engageBaseline = nil
            return effects
        case .dismissing:
            state = .releasing
            settledFrames = 0
            return []
        case .idle, .releasing:
            return []
        }
    }

    private func handleFrameChange(_ top: CGFloat) -> [KeyboardSyncEffect] {
        switch state {
        case .idle, .scrolling:
            // In scrolling the observer is read-only, so notifications may still
            // own the inset (they essentially never fire mid-drag anyway).
            return [.applyAnimated(.keyboardTop(top))]
        case .dismissing, .releasing:
            return [.ignoreKeyboardNotification]
        }
    }

    private func handleHeightChange(keyboardOpen: Bool) -> [KeyboardSyncEffect] {
        var effects: [KeyboardSyncEffect] = [.invalidateComposerIntrinsicSize]
        // Explicit inset apply only when idle AND keyboard down: the docked bar
        // grew so the resting overlap grew. Keyboard up while idle: the accessory
        // resize fires its own frame change that owns the inset. While the link
        // is involved (scrolling/dismissing/releasing), never apply here.
        if state == .idle, !keyboardOpen {
            effects.append(.applyAnimated(.resting))
        }
        return effects
    }

    private mutating func handleTick(_ top: CGFloat) -> [KeyboardSyncEffect] {
        switch state {
        case .idle:
            return []
        case .scrolling:
            // Observer: write nothing until the composer actually moves, which is
            // the only reliable signal that the interactive dismiss engaged.
            guard linkActive else { return [] }
            guard let base = engageBaseline else {
                engageBaseline = top
                lastComposerTop = top
                return []
            }
            lastComposerTop = top
            if abs(top - base) > engageThreshold {
                state = .dismissing
                return [.applyPerFrame(composerTop: top)]
            }
            return []
        case .dismissing:
            // Finger down: glue the inset, never settle.
            lastComposerTop = top
            return [.applyPerFrame(composerTop: top)]
        case .releasing:
            defer { lastComposerTop = top }
            if let last = lastComposerTop, abs(top - last) < settleEpsilon {
                settledFrames += 1
                if settledFrames >= settleFrameThreshold {
                    state = .idle
                    settledFrames = 0
                    linkActive = false
                    engageBaseline = nil
                    return [.stopLink, .reconcile]
                }
                return [.applyPerFrame(composerTop: top)]
            }
            settledFrames = 0
            return [.applyPerFrame(composerTop: top)]
        }
    }
}
