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

    /// The keyboard's notifications, as recorded app-wide (inject the app's
    /// tracker so a dock made while the keyboard is up starts on it); this
    /// dock reads its frames through `keyboardFrame(notified:)` in its window.
    private let keyboard: MobileKeyboardFrameTracker

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
    ///   - keyboard: the app's keyboard tracker.
    public init(view: UIView, usesBottomSafeArea: Bool, keyboard: MobileKeyboardFrameTracker) {
        self.view = view
        self.keyboard = keyboard
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
        keyboard.subscribe(self) { [weak self] _, change in
            guard let self else { return }
            switch change {
            case .willChangeFrame: self.follow()
            case .didChangeFrame: self.keyboardDidChangeFrame()
            }
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
        guard view != nil else { return 0 }
        let covered = keyboard.lastEndFrame.map { overlap(of: keyboardFrame(notified: $0)) } ?? 0
        return -max(covered, restInset)
    }

    /// The resting line's distance above the view's bottom edge.
    private var restInset: CGFloat {
        guard let view, usesBottomSafeArea else { return 0 }
        return view.safeAreaInsets.bottom
    }

    /// How far a keyboard at `screenFrame` (this app's screen coordinates)
    /// covers the view from its bottom edge.
    private func overlap(of screenFrame: CGRect) -> CGFloat {
        guard let view, let window = view.window else { return 0 }
        return MobileKeyboardReservation(
            keyboardFrameInWindow: window.convert(screenFrame, from: nil),
            viewFrameInWindow: view.convert(view.bounds, to: window)
        ).height
    }

    /// A keyboard notification's frame in this app's screen coordinates, for
    /// anything in this dock's window that reads keyboard notifications.
    ///
    /// An iPhone app on an iPad (iOS 27.0 simulator) sees a 375 x 667 screen
    /// while the iPad's own keyboard spans the iPad's screen, and the
    /// notifications carry that keyboard in iPad points: `0, 881, 820 x 299`
    /// on an 820 x 1180 iPad, whose bottom edge is the iPad screen's. The
    /// app's window fills the iPad's height (scaled 1180 / 667), so the
    /// keyboard's top in the app is 881 x 667 / 1180 = 498 pt, where the
    /// system guide and the screen put it. A frame wider than the app's
    /// screen is scaled that way, shown or hidden as `showing` says (default:
    /// the tracker's reading of the latest frame; a hidden frame starts at the
    /// iPad's bottom). A shown frame in iPad points that is not full width (a
    /// floating or split iPad keyboard) docks nothing: `.zero`.
    public func keyboardFrame(notified end: CGRect, showing: Bool? = nil) -> CGRect {
        guard let screen = view?.window?.screen.bounds, end.maxY > 0 else { return end }
        if end.width > screen.width + 1 {
            let height = end.height * screen.height / end.maxY
            let top = showing ?? keyboard.isShown ? screen.maxY - height : screen.maxY
            return CGRect(x: screen.minX, y: top, width: screen.width, height: height)
        }
        // On screen, yet reaching below this screen's bottom: iPad points.
        if end.minY < screen.maxY - 0.5, end.maxY > screen.maxY + 1 { return .zero }
        return end
    }

    private func follow() {
        // UIKit has decided where the keyboard goes: any drag hand-off ends,
        // also for a view out of its window (its next layout re-reads it).
        holdingAfterDrag = false
        fingerDrag = false
        let handedBack = followNotifications()
        guard let view, view.window != nil else { return }
        let constant = notifiedConstant
        guard handedBack || notifiedTop.constant != constant else { return }
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
    private func keyboardDidChangeFrame() {
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
            let constant = min(-restInset, max(docked, finger - view.bounds.maxY))
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
            _ = followNotifications()
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

    /// Back on the notified keyboard from a drag's system guide; whether it
    /// was on the system guide.
    private func followNotifications() -> Bool {
        guard systemTop.isActive else { return false }
        systemTop.isActive = false
        notifiedTop.isActive = true
        return true
    }
}
#endif
