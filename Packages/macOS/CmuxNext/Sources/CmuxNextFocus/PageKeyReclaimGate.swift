/// When a cmux window may take the keyboard back from a Chromium page window
/// (`FocusEffectApplier.reclaimKeyFromPageWindow`).
///
/// Hang B (macOS matrix fuzz, macOS 15.7.7, seed 21, 2026-10-24): main hung
/// 10 s inside `makeKeyWindow` from the reclaim, under Settings opening a
/// workspace (`showWorkspace` -> `didShow` -> focus -> blur -> reclaim). A key
/// change sends focus work again (`didBecomeKey` -> the focus model -> a blur),
/// so a reclaim could start another reclaim from inside its own `makeKey`, and
/// it asked a window that was not on screen (a workspace being shown, a
/// miniaturized window) to become key while a menu or Settings held the keys.
/// The gate allows one reclaim per focus apply, none from inside another, none
/// for a window that is not visible or is miniaturized, and none while a menu
/// tracks. Value state only: the applier owns one, tests drive it directly.
///
/// ```swift
/// var gate = PageKeyReclaimGate()
/// gate.beginApply()
/// _ = gate.reclaim(windowIsShown: true, menuIsTracking: false) { window.makeKey() }
/// ```
public nonisolated struct PageKeyReclaimGate: Sendable {
    /// A reclaim's `makeKey` is running: a key change it causes must not start another.
    private var isReclaiming = false
    /// The focus apply that already reclaimed once; nil when none did yet.
    private var reclaimedApply: UInt64?
    /// Focus applies seen (`beginApply`).
    public private(set) var apply: UInt64 = 0
    /// Reclaims the gate let through since it was made (tests, `debug.focus`).
    public private(set) var reclaims = 0

    /// A gate that has seen no focus apply yet.
    public init() {}

    /// A new focus apply starts: it may reclaim once.
    public mutating func beginApply() { apply &+= 1 }

    /// Runs `makeKey` when a reclaim is allowed now.
    ///
    /// - Parameters:
    ///   - windowIsShown: the cmux window is visible and not miniaturized.
    ///   - menuIsTracking: a menu (a context menu, the menu bar) tracks the mouse now.
    ///   - makeKey: makes the cmux window key.
    /// - Returns: Whether `makeKey` ran.
    public mutating func reclaim(windowIsShown: Bool, menuIsTracking: Bool, makeKey: () -> Void) -> Bool {
        guard !isReclaiming, reclaimedApply != apply, windowIsShown, !menuIsTracking else { return false }
        reclaimedApply = apply
        reclaims += 1
        isReclaiming = true
        makeKey()
        isReclaiming = false
        return true
    }
}
