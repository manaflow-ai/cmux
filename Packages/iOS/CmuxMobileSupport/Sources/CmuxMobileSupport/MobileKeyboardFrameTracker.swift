#if canImport(UIKit)
public import SwiftUI
public import UIKit

/// App-lifetime record of the software keyboard's most recent end frame.
///
/// UIKit posts keyboard frame notifications regardless of which views are
/// installed in a window, but a view-attached `keyboardWillChangeFrame`
/// handler misses every transition that happens while its view is detached
/// (for example across a workspace switch). A host that reads this tracker on
/// window attach can seat its dock at the real keyboard edge instead of the
/// stale pre-detach state. The composition root owns the app-wide instance
/// and injects it through ``EnvironmentValues/mobileKeyboardFrameTracker`` so
/// its record spans host view lifetimes.
///
/// The recorded frame is screen-space, exactly as UIKit broadcasts it to
/// every scene in the process. Consumers convert it through their OWN window
/// and intersect it with their own bounds (``MobileKeyboardReservation``), so
/// a multi-scene iPad read yields the overlap the keyboard actually has over
/// that scene's window; a scene the keyboard does not cover resolves to zero
/// reservation. A per-scene visibility difference observed while a host was
/// detached self-corrects on the next keyboard notification in that scene,
/// the same convergence UIKit's own process-wide broadcast relies on.
@MainActor
public final class MobileKeyboardFrameTracker {
    /// The keyboard's most recent end frame in screen coordinates, or `nil`
    /// before the first keyboard notification observed by this instance.
    public private(set) var lastEndFrame: CGRect?
    /// Whether the latest end frame puts the keyboard on screen. A hidden
    /// keyboard's frame starts where a shown one ends (the screen's bottom
    /// edge, in whatever coordinates UIKit posted), so this holds even when
    /// the frames are in another screen's points (an iPhone app on an iPad).
    public private(set) var isShown = false
    /// The bottom edge of the latest on-screen frame.
    private var shownBottom: CGFloat?
    /// The latest will-change: its end frame, when it came and how long
    /// UIKit animates it.
    private var latestWill: (frame: CGRect, time: CFTimeInterval, duration: TimeInterval, curve: Int)?
    /// The animation of the transition the latest will-change cut short,
    /// when it carries none of its own; see ``interruptedAnimation``.
    public private(set) var interruptedAnimation: (duration: TimeInterval, curve: UIView.AnimationCurve)?
    private let now: () -> CFTimeInterval

    /// Which keyboard notification a subscriber hears.
    public enum Change: Sendable {
        case willChangeFrame, didChangeFrame
    }

    private var subscribers: [(owner: () -> AnyObject?, handler: @MainActor (CGRect, Change) -> Void)] = []

    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    private nonisolated let notificationCenter: NotificationCenter

    /// Creates a tracker subscribed to the keyboard frame notifications.
    /// - Parameters:
    ///   - now: the clock notifications are timed by (tests inject one).
    public init(notificationCenter: NotificationCenter = .default, now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.notificationCenter = notificationCenter
        self.now = now
        // will + did both update the record: `will` keeps an attach that lands
        // mid-transition current, `did` corrects a transition UIKit retargeted
        // after the `will` payload was posted (unless it is an interruption's
        // notice: `isStale(didChangeTo:)`).
        let changes: [(Notification.Name, Change)] = [
            (UIResponder.keyboardWillChangeFrameNotification, .willChangeFrame),
            (UIResponder.keyboardDidChangeFrameNotification, .didChangeFrame),
        ]
        tokens = changes.map { name, change in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let info = notification.userInfo
                let endFrame = info?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0
                let curve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
                MainActor.assumeIsolated { // main-proof: observer on queue: .main
                    self?.record(change: change, endFrame: endFrame, duration: duration, curve: curve)
                }
            }
        }
    }

    /// Calls `handler` with the end frame of every keyboard notification after
    /// this tracker has recorded it, inside UIKit's posting (and so the
    /// keyboard's animation: `UIView.inheritedAnimationDuration` is live),
    /// for as long as `owner` lives.
    public func subscribe(_ owner: AnyObject, handler: @escaping @MainActor (CGRect, Change) -> Void) {
        subscribers.append((owner: { [weak owner] in owner }, handler: handler))
    }

    /// Whether a did-change notification is the notice of a transition
    /// that a newer one interrupts, not where the keyboard is going.
    ///
    /// The keyboard toggled again while it moves (iOS 26.5 simulator, the
    /// terminal's keyboard key 0.05 to 0.45 s into a hide or a show): UIKit
    /// posts the interrupted transition's did-change and did-show/did-hide,
    /// carrying the NEW end frame (or a 0-high one), about 5 ms before the
    /// new transition's will-change. Recording it put the keyboard at its new
    /// place before its animation began, and a layout pass then (the
    /// terminal settles its stack on did-hide) moved the dock there in one
    /// frame: the composer jumped (user report 2026-11-05). Such a did comes
    /// while the latest will's animation still runs and disagrees with its
    /// frame. A did that disagrees after that animation's end still counts:
    /// UIKit retargeted the transition after posting its will.
    public func isStale(didChangeTo endFrame: CGRect) -> Bool {
        guard let will = latestWill, !Self.same(endFrame, will.frame) else { return false }
        return now() < will.time + will.duration
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    private func record(change: Change, endFrame: CGRect?, duration: TimeInterval, curve: Int) {
        // An interruption's notice: the new transition's will comes next.
        if let endFrame, change == .didChangeFrame, isStale(didChangeTo: endFrame) { return }
        if let endFrame {
            if change == .willChangeFrame {
                let time = now()
                // A will that cuts a running transition short with no
                // animation of its own (a show reversed 0.05 s in: dur 0)
                // takes the cut transition's, so a dock riding it carries on
                // from where it is.
                if duration <= 0, let cut = latestWill, time < cut.time + cut.duration, !Self.same(cut.frame, endFrame) {
                    // UIKit's keyboard curve (7) is private; the dock passes its raw value through.
                    interruptedAnimation = (cut.duration, UIView.AnimationCurve(rawValue: cut.curve) ?? .easeInOut)
                } else {
                    interruptedAnimation = nil
                }
                latestWill = (endFrame, time, duration, curve)
            }
            lastEndFrame = endFrame
            isShown = endFrame.height > 0 && endFrame.minY < (shownBottom ?? .greatestFiniteMagnitude) - 0.5
            if isShown { shownBottom = endFrame.maxY }
        }
        guard let endFrame else { return }
        subscribers.removeAll { $0.owner() == nil }
        for subscriber in subscribers { subscriber.handler(endFrame, change) }
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// The keyboard's current bottom overlap of `view`, or `nil` when no
    /// keyboard notification has been observed yet. Floating and split iPad
    /// keyboards resolve to zero overlap through the shared reservation math.
    public func currentOverlap(in view: UIView) -> CGFloat? {
        guard let lastEndFrame, let window = view.window else { return nil }
        let keyboardFrameInWindow = window.convert(lastEndFrame, from: nil)
        let viewFrameInWindow = view.convert(view.bounds, to: window)
        return MobileKeyboardReservation(
            keyboardFrameInWindow: keyboardFrameInWindow,
            viewFrameInWindow: viewFrameInWindow
        ).height
    }

    /// Whether the keyboard is currently visible to `view`, or `nil` when no
    /// keyboard notification has been observed yet.
    public func currentVisibility(in view: UIView) -> Bool? {
        guard let lastEndFrame, let window = view.window else { return nil }
        let keyboardFrameInWindow = window.convert(lastEndFrame, from: nil)
        let viewFrameInWindow = view.convert(view.bounds, to: window)
        return MobileKeyboardVisibility(
            keyboardFrameInWindow: keyboardFrameInWindow,
            viewFrameInWindow: viewFrameInWindow
        ).isVisible
    }
}

extension EnvironmentValues {
    /// The composition-root-owned keyboard frame tracker, `nil` when the app
    /// shell has not injected one (previews, isolated harnesses).
    @Entry public var mobileKeyboardFrameTracker: MobileKeyboardFrameTracker? = nil
}
#endif
