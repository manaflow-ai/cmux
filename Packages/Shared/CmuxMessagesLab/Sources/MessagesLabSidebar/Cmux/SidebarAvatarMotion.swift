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
/// - the app is not active, or the list's window is hidden, minimized or covered (its occlusion
///   state): ``CmuxSidebarView`` re-applies every avatar when either changes.
enum SidebarAvatarMotion {
    /// What a conversation's avatar does: nil stands still.
    enum Mode: String, Codable, Hashable, Sendable {
        case idle
        case working
    }

    /// The layer key the loop is added under, and the KVC key holding the shown mode.
    static let animationKey = "cmux.avatarMotion"
    private static let modeKey = "cmux.avatarMotion.mode"

    /// Tests' pin for "the app is active and the window is on screen" (an offscreen test window never is).
    @MainActor static var onScreenOverride: Bool?

    /// Whether loops may run in `window` now: the host's gate (Reduce Motion included), the app is
    /// active and the window is on screen.
    @MainActor static func mayRun(in window: NSWindow?) -> Bool {
        guard !CmuxSidebarView.reducesMotion, CmuxSidebarView.avatarLoopGate?() ?? true else { return false }
        if let onScreenOverride { return onScreenOverride }
        guard NSApp?.isActive ?? false, let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else { return false }
        return true
    }

    /// Shows `mode` on the avatar `layer` of conversation `seed` (its id: each avatar's loop starts at
    /// its own phase, so a list of Chiefs doesn't move in lockstep). Keeps a running loop of the same
    /// mode and style; replaces one that differs; removes it when `mode` is nil or loops may not run.
    @MainActor static func apply(_ layer: CALayer, mode: Mode?, seed: String, window: NSWindow?) {
        let style = CmuxSidebarView.avatarMotionStyle
        let wanted = mode.flatMap { mayRun(in: window) && style != .still ? "\(style.rawValue).\($0.rawValue)" : nil }
        layer.setValue(mode?.rawValue, forKey: modeKey)
        layer.setValue(seed, forKey: modeKey + ".seed")
        let shown = layer.animation(forKey: animationKey)?.value(forKey: modeKey) as? String
        guard shown != wanted else { return }
        layer.removeAnimation(forKey: animationKey)
        guard let wanted, let mode else { return }
        let loop = animation(style, mode: mode, seed: seed)
        loop.setValue(wanted, forKey: modeKey)
        layer.add(loop, forKey: animationKey)
    }

    /// Re-applies the mode `layer` last showed (after a gate, app or window change).
    @MainActor static func refresh(_ layer: CALayer, window: NSWindow?) {
        guard let mode = (layer.value(forKey: modeKey) as? String).flatMap(Mode.init(rawValue:)) else {
            layer.removeAnimation(forKey: animationKey)
            return
        }
        apply(layer, mode: mode, seed: layer.value(forKey: modeKey + ".seed") as? String ?? "", window: window)
    }

    /// Stops the loop (the layer goes back to the pool).
    static func stop(_ layer: CALayer) {
        layer.removeAnimation(forKey: animationKey)
        layer.setValue(nil, forKey: modeKey)
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
