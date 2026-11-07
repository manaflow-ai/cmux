#if canImport(UIKit)
public import UIKit

/// Taps on controls that ride a moving view, where the person sees them.
///
/// UIKit hit-tests a touch against model layers, which an animation sets to
/// its end at once, while the screen shows presentation layers. A control in
/// a stack that rides the keyboard is drawn up to a keyboard's height away
/// from where UIKit looks for it until the animation ends: a finger on the
/// terminal's keyboard key mid-transition reached the terminal, a glass key's
/// lift view or, while the keyboard rose, the keyboard itself (which owns its
/// end frame at once), so the key could not reverse a moving keyboard
/// (KeyboardToggleInterruptUITests, 10 of 15 mid-animation presses).
///
/// The app's `UIApplication` (``Routing``) asks ``route(_:)`` first in `sendEvent(_:)`. A touch
/// that begins inside a registered target's drawn frame while its host is
/// drawn away from its model position, and outside the target's model frame
/// (where UIKit's own routing still reaches it), belongs to the target: its
/// events are consumed and its lift fires the target's action, as the
/// control's tap would. Everything else goes on to UIKit untouched.
@MainActor
public final class MobileMovingTapTargets {
    /// The app's router: the one its `UIApplication` offers events to, `nil`
    /// in a process whose application has none (tests, extensions).
    public static var app: MobileMovingTapTargets? {
        (UIApplication.shared as? Routing)?.movingTapTargets
    }

    /// An application that offers its events to ``route(_:)`` first.
    @MainActor
    public protocol Routing: AnyObject {
        var movingTapTargets: MobileMovingTapTargets { get }
    }

    private struct Target {
        weak var host: UIView?
        /// The control's frame in `host`'s coordinates (its layout frame).
        let frame: () -> CGRect?
        let action: () -> Void
    }

    private var targets: [ObjectIdentifier: Target] = [:]
    /// Touches a target owns, until they end, with the target's key.
    private var claimed: [ObjectIdentifier: ObjectIdentifier] = [:]

    public init() {}

    /// How many targets are registered (probes).
    public var count: Int { targets.count }

    /// Registers (or replaces) `owner`'s target: the control at `frame()` in
    /// `host`, which performs `action` on a tap.
    public func register(
        _ owner: AnyObject,
        host: UIView,
        frame: @escaping () -> CGRect?,
        action: @escaping () -> Void
    ) {
        targets[ObjectIdentifier(owner)] = Target(host: host, frame: frame, action: action)
    }

    public func unregister(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        targets[key] = nil
        claimed = claimed.filter { $0.value != key }
    }

    /// Whether a touch beginning at `point` in `window` would go to a target
    /// UIKit's routing misses: inside its drawn frame, outside its model frame.
    public func claims(_ point: CGPoint, in window: UIWindow) -> Bool {
        target(at: point, in: window) != nil
    }

    /// The drawn centres of the registered targets in `window`, for probes.
    public func drawnCentres(in window: UIWindow) -> [CGPoint] {
        targets.values.compactMap { target in
            guard let frames = frames(of: target, in: window) else { return nil }
            return CGPoint(x: frames.drawn.midX, y: frames.drawn.midY)
        }
    }

    /// Takes the touches of `event` that belong to a target; `true` when all
    /// of its touches did, so the caller does not send it on.
    public func route(_ event: UIEvent) -> Bool {
        guard event.type == .touches, let touches = event.allTouches, !touches.isEmpty else { return false }
        var allClaimed = true
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if touch.phase == .began, claimed[id] == nil, let key = target(touchedBy: touch) {
                claimed[id] = key
            }
            guard let key = claimed[id] else {
                allClaimed = false
                continue
            }
            switch touch.phase {
            case .ended:
                claimed[id] = nil
                targets[key]?.action()
            case .cancelled:
                claimed[id] = nil
            default:
                break
            }
        }
        return allClaimed
    }

    private func target(at point: CGPoint, in window: UIWindow) -> ObjectIdentifier? {
        for (key, target) in targets {
            guard let frames = frames(of: target, in: window) else { continue }
            if frames.drawn.contains(point), !frames.model.contains(point) { return key }
        }
        return nil
    }

    /// The target a beginning touch lands on, in whichever window UIKit gave
    /// it (the keyboard's own window included).
    private func target(touchedBy touch: UITouch) -> ObjectIdentifier? {
        guard let touchWindow = touch.window else { return nil }
        let point = touch.location(in: touchWindow)
        for (key, target) in targets {
            guard let window = target.host?.window, let frames = frames(of: target, in: window) else { continue }
            let local = window.convert(point, from: touchWindow)
            if frames.drawn.contains(local), !frames.model.contains(local) { return key }
        }
        return nil
    }

    /// The target's frame in `window` as laid out and as drawn, when its host
    /// is on screen in `window` and drawn away from its layout position.
    private func frames(of target: Target, in window: UIWindow) -> (model: CGRect, drawn: CGRect)? {
        guard let host = target.host, host.window === window, !host.isHidden, let local = target.frame(), !local.isEmpty
        else { return nil }
        let hostModel = host.convert(host.bounds, to: window)
        let hostDrawn = MobileKeyboardProbe().onScreen(host, in: window)
        let dx = hostDrawn.minX - hostModel.minX
        let dy = hostDrawn.minY - hostModel.minY
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return nil }
        let model = host.convert(local, to: window)
        return (model, model.offsetBy(dx: dx, dy: dy))
    }
}
#endif
