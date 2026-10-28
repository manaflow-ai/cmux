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
/// drag began. Otherwise the finger places the keyboard: UIKit puts its top
/// edge at the finger plus the guide's `keyboardDismissPadding` once the
/// finger is below the keyboard's top edge, which is what the keyboard did on
/// screen while the system guide and the keyboard's placeholder stayed put.
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
    /// The last will-show / will-hide: whether the keyboard is on screen.
    private static var keyboardShown = false

    private weak var view: UIView?
    private let usesBottomSafeArea: Bool
    /// `guide.top == view.bottom + constant`: the notified keyboard, or where
    /// a drag left it.
    private let notifiedTop: NSLayoutConstraint
    /// `guide.top == system guide top`: during an interactive dismissal.
    private let systemTop: NSLayoutConstraint
    /// A drag moved the keyboard and let go; UIKit's notification for where
    /// the keyboard goes next has not come yet.
    private var holdingAfterDrag = false
    /// A drag over a shown keyboard that the finger places (the system guide
    /// did not follow the keyboard as the drag began).
    private var fingerDrag = false

    /// - Parameters:
    ///   - view: the view the composer lives in.
    ///   - usesBottomSafeArea: rest on the bottom safe-area edge (as
    ///     `UIKeyboardLayoutGuide.usesBottomSafeArea`), else on the view's bottom.
    public init(view: UIView, usesBottomSafeArea: Bool) {
        self.view = view
        self.usesBottomSafeArea = usesBottomSafeArea
        let system = view.keyboardLayoutGuide
        system.followsUndockedKeyboard = false
        system.usesBottomSafeArea = usesBottomSafeArea
        guide.identifier = Self.guideIdentifier
        view.addLayoutGuide(guide)
        notifiedTop = guide.topAnchor.constraint(equalTo: view.bottomAnchor)
        systemTop = guide.topAnchor.constraint(equalTo: system.topAnchor)
        super.init()
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            notifiedTop,
        ])
        notifiedTop.constant = notifiedConstant
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidChangeFrame(_:)),
                           name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
            center.addObserver(self, selector: #selector(keyboardWillShowOrHide(_:)), name: name, object: nil)
        }
    }

    /// Whether an interactive dismissal is handing the guide to the system
    /// keyboard layout guide right now.
    public var isFollowingSystemGuide: Bool { systemTop.isActive }

    /// Follows the keyboard through `scrollView`'s interactive dismissals
    /// (`keyboardDismissMode = .interactive`).
    public func trackInteractiveDismissal(of scrollView: UIScrollView) {
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
    }

    /// Re-reads the notified keyboard against the view's current frame and
    /// safe area (the view moved, resized or rotated while the keyboard
    /// stayed). Call it from the view's layout pass.
    public func refresh() {
        guard !systemTop.isActive, !holdingAfterDrag, !fingerDrag else { return }
        let constant = notifiedConstant
        if notifiedTop.constant != constant { notifiedTop.constant = constant }
    }

    /// `guide.top - view.bottom` for the notified keyboard: the keyboard's
    /// overlap of the view's bottom edge, at least the resting line's.
    private var notifiedConstant: CGFloat {
        guard let view else { return 0 }
        let rest = usesBottomSafeArea ? view.safeAreaInsets.bottom : 0
        return -max(Self.lastEndFrame.map(overlap(of:)) ?? 0, rest)
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
        follow(note)
    }

    @objc private func keyboardWillShowOrHide(_ note: Notification) {
        Self.keyboardShown = note.name == UIResponder.keyboardWillShowNotification
        // Only a frame that needs the show / hide state (see `screenFrame`)
        // moves the dock here; will-change already placed every other one.
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = view?.window?.screen.bounds, end.width > screen.width + 1 else { return }
        follow(note)
    }

    /// The notified frame in this app's screen coordinates.
    ///
    /// An iPhone app on an iPad (iOS 27.0 simulator) sees a 375 x 667 screen
    /// while the iPad's own keyboard spans the iPad's screen, and the
    /// notifications carry that keyboard in iPad points: `0, 881, 820 x 299`
    /// on an 820 x 1180 iPad, whose bottom edge is the iPad screen's. The
    /// app's window fills the iPad's height (scaled 1180 / 667), so the
    /// keyboard's top in the app is 881 x 667 / 1180 = 498 pt, where the
    /// system guide and the screen put it. A frame wider than the app's
    /// screen is scaled that way; whether it is on screen comes from the
    /// last will-show / will-hide (a hidden frame starts at the iPad's bottom).
    private func screenFrame(_ end: CGRect) -> CGRect {
        guard let screen = view?.window?.screen.bounds, end.width > screen.width + 1, end.maxY > 0 else { return end }
        let height = end.height * screen.height / end.maxY
        let top = Self.keyboardShown ? screen.maxY - height : screen.maxY
        return CGRect(x: screen.minX, y: top, width: screen.width, height: height)
    }

    private func follow(_ note: Notification) {
        guard let raw = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        Self.lastEndFrame = screenFrame(raw)
        // UIKit has decided where the keyboard goes: any drag hand-off ends,
        // also for a view out of its window (its next layout re-reads it).
        holdingAfterDrag = false
        fingerDrag = false
        followNotifications()
        guard let view, view.window != nil else { return }
        let constant = notifiedConstant
        guard notifiedTop.constant != constant else { return }
        notifiedTop.constant = constant
        view.setNeedsLayout()
        // UIKit posts these inside the keyboard's animation; a nested animation
        // inherits its remaining duration and curve, so the composer rides it.
        let remaining = UIView.inheritedAnimationDuration
        guard remaining > 0 else {
            view.layoutIfNeeded()
            return
        }
        // motion: allow inherits the system keyboard's own animation; it adds no animation of its own.
        UIView.animate(withDuration: remaining, delay: 0, options: [.beginFromCurrentState]) { view.layoutIfNeeded() }
    }

    /// A keyboard that settled with no will-change notification after a drag
    /// (a dismissal the finger called off): back on the notified keyboard.
    @objc private func keyboardDidChangeFrame(_ note: Notification) {
        guard holdingAfterDrag, let view, view.window != nil else { return }
        holdingAfterDrag = false
        refresh()
        view.layoutIfNeeded()
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let view else { return }
        switch pan.state {
        case .began:
            // Only a drag over a shown keyboard can move it.
            let restingTop = view.bounds.maxY - (usesBottomSafeArea ? view.safeAreaInsets.bottom : 0)
            let top = guide.layoutFrame.minY
            guard !systemTop.isActive, !fingerDrag, top < restingTop - 0.5 else { return }
            holdingAfterDrag = false
            if abs(view.keyboardLayoutGuide.layoutFrame.minY - top) < 1 {
                // The system guide follows the keyboard: it tracks the drag.
                notifiedTop.isActive = false
                systemTop.isActive = true
            } else {
                // An iOS 27 guide that reads a docked keyboard as undocked
                // would drop the composer under the keyboard: the finger
                // places it instead.
                fingerDrag = true
            }
        case .changed:
            guard fingerDrag else { return }
            let docked = notifiedConstant
            let finger = pan.location(in: view).y + max(0, view.keyboardLayoutGuide.keyboardDismissPadding)
            let constant = min(0, max(docked, finger - view.bounds.maxY))
            guard abs(notifiedTop.constant - constant) > 0.01 else { return }
            notifiedTop.constant = constant
            UIView.performWithoutAnimation { view.layoutIfNeeded() }
        case .possible:
            break
        default:
            guard systemTop.isActive || fingerDrag else { return }
            // Where the finger left the keyboard. UIKit moves its guide to rest
            // before the keyboard's own animation (and notification) start, so
            // a keyboard the drag moved holds there until that notification.
            let top = guide.layoutFrame.minY
            fingerDrag = false
            followNotifications()
            let notified = notifiedConstant
            let dragged = top - view.bounds.maxY
            if abs(dragged - notified) > 0.5 {
                notifiedTop.constant = dragged
                holdingAfterDrag = true
            } else {
                notifiedTop.constant = notified
            }
        }
    }

    private func followNotifications() {
        guard systemTop.isActive else { return }
        systemTop.isActive = false
        notifiedTop.isActive = true
    }
}
#endif
