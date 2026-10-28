#if canImport(UIKit)
public import UIKit

/// Where a bottom composer docks: a layout guide whose top edge is the docked
/// software keyboard's top edge in its view, or the view's resting line when
/// no docked keyboard covers the view's bottom edge.
///
/// Pin a composer to ``guide`` instead of `view.keyboardLayoutGuide`. The
/// keyboard's notified frame places it, applied inside the keyboard's own
/// animation, so shows and hides ride the keyboard's curve. During an
/// interactive dismissal it follows UIKit's keyboard layout guide, which
/// tracks the finger frame by frame.
///
/// The system guide alone is not enough on iOS 27.0 (simulator 24A434): with a
/// hardware keyboard attached it can read a full-width keyboard at the bottom
/// as undocked and sit at the bottom edge, so a composer pinned to it stayed
/// under the keyboard (Chief on its first show; the terminal after a rotation,
/// with no keyboard notification at all; verify/keyboard-pin.md). A drag uses
/// the system guide only when it agreed with the notified keyboard as the
/// drag began.
///
/// Only a keyboard that reaches the view's bottom edge counts
/// (``MobileKeyboardReservation``): a floating or split keyboard leaves the
/// composer at rest.
@MainActor
public final class MobileKeyboardDock: NSObject {
    /// Top: the docked keyboard's top edge, or the resting line. Bottom: the
    /// view's bottom edge. Full width.
    public let guide = UILayoutGuide()
    /// ``guide``'s `identifier`, for tools that look for it in a view.
    public static let guideIdentifier = "MobileKeyboardDock"

    /// The keyboard's latest notified end frame, screen coordinates, shared
    /// by every dock so a dock made while the keyboard is up starts on it.
    private static var lastEndFrame: CGRect?

    private weak var view: UIView?
    /// `guide.top <= view.bottom - overlap`: the notified keyboard.
    private let notifiedTop: NSLayoutConstraint
    /// `guide.top == system guide top`: during an interactive dismissal.
    private let systemTop: NSLayoutConstraint
    /// A drag ended and its keyboard notification has not come yet.
    private var holdingAfterDrag = false

    /// - Parameters:
    ///   - view: the view the composer lives in.
    ///   - usesBottomSafeArea: rest on the bottom safe-area edge (as
    ///     `UIKeyboardLayoutGuide.usesBottomSafeArea`), else on the view's bottom.
    public init(view: UIView, usesBottomSafeArea: Bool) {
        self.view = view
        let system = view.keyboardLayoutGuide
        system.followsUndockedKeyboard = false
        system.usesBottomSafeArea = usesBottomSafeArea
        guide.identifier = Self.guideIdentifier
        view.addLayoutGuide(guide)
        notifiedTop = guide.topAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        systemTop = guide.topAnchor.constraint(equalTo: system.topAnchor)
        // As low as the keyboard and the resting line allow.
        let pull = guide.topAnchor.constraint(equalTo: view.bottomAnchor)
        pull.priority = UILayoutPriority(999)
        var constraints = [
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notifiedTop, pull,
        ]
        if usesBottomSafeArea {
            constraints.append(guide.topAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor))
        }
        super.init()
        NSLayoutConstraint.activate(constraints)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    /// Whether an interactive dismissal is handing the guide to the system
    /// keyboard layout guide right now.
    public var isFollowingSystemGuide: Bool { systemTop.isActive }

    /// Follows the keyboard through `scrollView`'s interactive dismissals
    /// (`keyboardDismissMode = .interactive`).
    public func trackInteractiveDismissal(of scrollView: UIScrollView) {
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
    }

    /// Re-reads the notified keyboard against the view's current frame (the
    /// view moved or resized while the keyboard stayed). Call it from the
    /// view's layout pass.
    public func refresh() {
        guard !systemTop.isActive, !holdingAfterDrag else { return }
        let overlap = Self.lastEndFrame.map(overlap(of:)) ?? 0
        if notifiedTop.constant != -overlap { notifiedTop.constant = -overlap }
    }

    /// How far a keyboard at `screenFrame` covers the view from its bottom edge.
    private func overlap(of screenFrame: CGRect) -> CGFloat {
        guard let view, let window = view.window else { return 0 }
        return MobileKeyboardReservation(
            keyboardFrameInWindow: window.convert(screenFrame, from: nil),
            viewFrameInWindow: view.convert(view.bounds, to: window)
        ).height
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        Self.lastEndFrame = end
        guard let view, view.window != nil else { return }
        // UIKit has decided where the keyboard goes: any drag hand-off ends.
        holdingAfterDrag = false
        followNotifications()
        notifiedTop.constant = -overlap(of: end)
        view.setNeedsLayout()
        // UIKit posts this inside the keyboard's animation; a nested animation
        // inherits its remaining duration and curve, so the composer rides it.
        let remaining = UIView.inheritedAnimationDuration
        guard remaining > 0 else {
            view.layoutIfNeeded()
            return
        }
        // motion: allow inherits the system keyboard's own animation; it adds no animation of its own.
        UIView.animate(withDuration: remaining, delay: 0, options: [.beginFromCurrentState]) { view.layoutIfNeeded() }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let view else { return }
        switch pan.state {
        case .began:
            // Hand the drag to the system guide only where it agrees with the
            // keyboard: an iOS 27 guide that reads a docked keyboard as
            // undocked would drop the composer under it.
            let system = view.keyboardLayoutGuide.layoutFrame.minY
            guard !systemTop.isActive, abs(system - guide.layoutFrame.minY) < 1 else { return }
            holdingAfterDrag = false
            notifiedTop.isActive = false
            systemTop.isActive = true
        case .changed, .possible:
            break
        default:
            guard systemTop.isActive else { return }
            // Hold where the finger left the keyboard: UIKit moves its guide to
            // rest before the keyboard's own animation (and notification) start.
            notifiedTop.constant = guide.layoutFrame.minY - view.bounds.maxY
            followNotifications()
            holdingAfterDrag = true
        }
    }

    private func followNotifications() {
        guard systemTop.isActive else { return }
        systemTop.isActive = false
        notifiedTop.isActive = true
    }
}
#endif
