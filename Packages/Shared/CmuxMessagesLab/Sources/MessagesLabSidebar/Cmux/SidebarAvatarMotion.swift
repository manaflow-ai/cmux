import AppKit

/// cmux: a Chief's avatar in the list and the pinned grid moves (Leo 2026-11-01: "i also want them
/// animated like how chatgpt animates their dots"): a slow idle loop, livelier while the Chief works.
///
/// One Core Animation keyframe loop per avatar layer, run by the render server: no timer, display
/// link or main-thread work per frame. It is added once when a row or tile starts showing a moving
/// avatar and stays until something changes, so a reload that keeps the avatar keeps its loop.
///
/// Stop conditions (each removes the loop and leaves the avatar at rest):
/// - the row or tile goes back to the pool (scrolled away, the conversation gone): ``stop(_:)``;
/// - Reduce Motion, calm mode, `ui.animationSpeed` off or Home's motion switch off
///   (``CmuxSidebarView/avatarLoopGate``, the host's `Motion.home.animatesLoops`);
/// - the list's window is not key (the app went inactive, or another window took the keyboard), or
///   it is hidden or minimized: the list's own key tracking (`setWindowActive`) re-applies every
///   avatar, so no observer of its own is added.
///
/// The list's controller holds one (its host's gate and style); each row layer holds what its avatar
/// was asked to show (``Shown``), so a gate, app or window change re-applies it.
struct SidebarAvatarMotion {
    /// What a conversation's avatar does: nil stands still.
    enum Mode: String, Codable, Hashable, Sendable {
        case idle
        case working
    }

    /// What one avatar was asked to show, and the loop running on it (nil: at rest).
    struct Shown: Equatable {
        var mode: Mode
        var seed: String
        var loop: Loop?
    }

    /// A running loop's style and mode: a reload asking for the same keeps it.
    struct Loop: Equatable {
        var style: CmuxSidebarAvatarMotionStyle
        var mode: Mode
    }

    /// The layer key the loop is added under.
    static let animationKey = "cmux.avatarMotion"

    /// The host's gate for loops (cmux-next: `Motion.home.animatesLoops`); nil: only Reduce Motion decides.
    var gate: (@MainActor () -> Bool)?
    /// How avatars move (the host's Debug setting).
    var style = CmuxSidebarAvatarMotionStyle.float
    /// The list's window is key (the vendored list's key tracking sets it).
    var windowKey = true
    /// Tests' pin for "the window is on screen" (an offscreen test window never is).
    var onScreenPin: Bool?

    /// Whether loops may run in `window` now: the host's gate (Reduce Motion included), the window
    /// is key (so the app is active), shown and not minimized.
    @MainActor func mayRun(in window: NSWindow?) -> Bool {
        guard !CmuxSidebarView.reducesMotion, gate?() ?? true, windowKey else { return false }
        if let onScreenPin { return onScreenPin }
        // Not the occlusion state: the window server reports it after the window becomes key (a launch
        // or an un-minimize would leave the avatar still), and a key window is the frontmost one.
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return true
    }

    /// Shows `mode` on `row`'s avatar for conversation `seed` (its id: each avatar's loop starts at
    /// its own phase, so a list of Chiefs doesn't move in lockstep). Keeps a running loop of the same
    /// mode and style; replaces one that differs; removes it when `mode` is nil or loops may not run.
    @MainActor func apply(_ row: SidebarRowLayer, mode: Mode?, seed: String, window: NSWindow?) {
        guard let mode else { return Self.stop(row) }
        let wanted = mayRun(in: window) && style != .still ? Loop(style: style, mode: mode) : nil
        // The loop on screen, if it is still this conversation's (a layer reused for another restarts).
        let shown = row.avatarMotion
        let running = row.avatar.animation(forKey: Self.animationKey) == nil || shown?.seed != seed ? nil : shown?.loop
        row.avatarMotion = Shown(mode: mode, seed: seed, loop: wanted)
        guard running != wanted || (wanted == nil && row.avatar.animation(forKey: Self.animationKey) != nil) else { return }
        row.avatar.removeAnimation(forKey: Self.animationKey)
        if let wanted { row.avatar.add(Self.animation(wanted.style, mode: mode, seed: seed), forKey: Self.animationKey) }
    }

    /// Re-applies what `row`'s avatar last showed (after a gate, app or window change).
    @MainActor func refresh(_ row: SidebarRowLayer, window: NSWindow?) {
        apply(row, mode: row.avatarMotion?.mode, seed: row.avatarMotion?.seed ?? "", window: window)
    }

    /// Stops the loop (the layer goes back to the pool, or its conversation stands still).
    static func stop(_ row: SidebarRowLayer) {
        row.avatar.removeAnimation(forKey: animationKey)
        row.avatarMotion = nil
    }

    /// One loop: `style`'s keyframes at the mode's period and depth, starting at the seed's phase.
    static func animation(_ style: CmuxSidebarAvatarMotionStyle, mode: Mode, seed: String) -> CAKeyframeAnimation {
        let shape = style.shape(mode)
        let steps = 48
        // motion: allow the loop runs only while `mayRun` (Reduce Motion, calm mode, speed off and Home's
        // switch through the host's gate, the app active and the window visible) and is removed otherwise.
        let loop = CAKeyframeAnimation(keyPath: shape.keyPath)
        loop.values = (0...steps).map { NSNumber(value: shape.rest + shape.depth * shape.wave(Double($0) / Double(steps))) }
        loop.duration = shape.period
        loop.repeatCount = .infinity
        loop.calculationMode = .linear
        loop.isRemovedOnCompletion = false
        // A stable phase per conversation, so a reload or a scroll back never jumps the avatar.
        let phase = Double(seed.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 1000) / 1000
        loop.timeOffset = phase * shape.period
        return loop
    }
}

/// How a Chief's avatar moves (Debug Settings > Home > Avatar motion; the gallery's variants).
public enum CmuxSidebarAvatarMotionStyle: String, Sendable, CaseIterable {
    /// Bobs up and down by a point, like a held breath (the default).
    case float
    /// Grows and shrinks a few percent, ChatGPT's breathing dot.
    case breathe
    /// Tilts a few degrees side to side.
    case sway
    /// No motion.
    case still

    /// One loop's key path, rest value, depth, period and wave (0...1 to -1...1).
    struct Shape {
        var keyPath: String
        var rest: Double
        var depth: Double
        var period: CFTimeInterval
        var wave: (Double) -> Double
    }

    func shape(_ mode: SidebarAvatarMotion.Mode) -> Shape {
        let working = mode == .working
        let sine: (Double) -> Double = { sin($0 * 2 * .pi) }
        // Working: a quick double beat in each period, like ChatGPT's dot while it answers.
        let beat: (Double) -> Double = { t in max(0, sin(t * 4 * .pi)) * (t < 0.5 ? 1 : 0.6) }
        switch self {
        case .float:
            return Shape(keyPath: "transform.translation.y", rest: 0, depth: working ? 1.6 : 1.0,
                         period: working ? 0.9 : 3.2, wave: sine)
        case .breathe:
            return working ? Shape(keyPath: "transform.scale", rest: 1, depth: 0.07, period: 1.1, wave: beat)
                : Shape(keyPath: "transform.scale", rest: 1.0175, depth: 0.0175, period: 3.6, wave: sine)
        case .sway:
            return Shape(keyPath: "transform.rotation.z", rest: 0, depth: (working ? 5 : 2.5) * .pi / 180,
                         period: working ? 1.0 : 4.0, wave: sine)
        case .still:
            return Shape(keyPath: "transform.scale", rest: 1, depth: 0, period: 1, wave: { _ in 0 })
        }
    }
}

extension SidebarController {
    /// cmux: re-applies every row's and tile's avatar motion (the window's key state changed).
    func refreshAvatarMotion() {
        for l in rowLayers.values + tileLayers { avatarMotion.refresh(l, window: document.window) }
    }
}
