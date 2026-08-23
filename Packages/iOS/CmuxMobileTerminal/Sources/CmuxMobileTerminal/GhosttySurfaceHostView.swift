#if canImport(UIKit)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// iOS 27 can leave `keyboardLayoutGuide` at the screen bottom while the keyboard is
/// visible. Only that OS uses notification-derived dock geometry; every other OS keeps
/// UIKit's system guide as the dock constraint authority.
private enum KeyboardDockGeometrySource {
    case systemLayoutGuide
    case keyboardNotifications

    static var current: Self {
        #if DEBUG
        if UITestConfig.forceIOS27KeyboardDockWorkaround {
            return .keyboardNotifications
        }
        #endif
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27
            ? .keyboardNotifications
            : .systemLayoutGuide
    }
}

/// UIKit root that owns terminal clipping, dock placement, and keyboard motion.
///
/// The terminal grid never resizes for the keyboard (see
/// `TerminalLetterboxGeometry.terminalContainerSize`): the render always has
/// its full keyboard-down height, and this host pins its bottom edge to the
/// dock (composer bar) with ONE constraint —
///
///     renderWrapper.bottom == dock.top + steadyBottomChromeReservation
///
/// so keyboard motion is a single animated layout pass moving the dock, with
/// the full-height render riding it and the top rows clipping behind the
/// screen top. There is no grid renegotiation to mask, so there is no wrapper
/// transform, no presentation-layer rebase on reversals, and no settle fold:
/// an interrupted reversal is just a constraint retarget under
/// `.beginFromCurrentState`. With the keyboard down the reservation constant
/// places the wrapper exactly at its natural position, so the steady state is
/// byte-identical to a keyboard-less layout.
///
/// Dock seat authority:
/// - chrome visible, non-iOS-27: `UIKeyboardLayoutGuide` (UIKit animates it).
/// - iOS 27, or chrome hidden on any OS: a plain bottom constraint this host
///   retargets from keyboard notifications. Chrome hidden cannot use the
///   guide because its safe-area fallback would hold the (invisible) dock —
///   and therefore the render bottom — 34pt above the screen bottom.
@MainActor
public final class GhosttySurfaceHostView: UIView {
    public let surfaceView: GhosttySurfaceView
    private let terminalClipView = UIView()
    private let terminalPresentationView = UIView()
    /// dock.bottom == host.bottom + c; active whenever this host owns the seat.
    private var dockBottomConstraint: NSLayoutConstraint!
    /// dock.bottom == keyboardLayoutGuide.top; active on guide-source OSes
    /// while the chrome is visible.
    private var guideDockConstraint: NSLayoutConstraint?
    /// renderWrapper.bottom == dock.top + steady chrome reservation.
    private var presentationBottomConstraint: NSLayoutConstraint!
    private let keyboardDockGeometrySource = KeyboardDockGeometrySource.current
    #if DEBUG
    private var maximumTerminalDockPresentationGap: CGFloat = 0
    #endif

    public init(surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: surfaceView.frame)

        backgroundColor = surfaceView.backgroundColor
        clipsToBounds = false

        terminalClipView.backgroundColor = surfaceView.backgroundColor
        terminalClipView.clipsToBounds = true
        terminalClipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalClipView)

        terminalPresentationView.backgroundColor = surfaceView.backgroundColor
        terminalPresentationView.translatesAutoresizingMaskIntoConstraints = false
        terminalClipView.addSubview(terminalPresentationView)

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        terminalPresentationView.addSubview(surfaceView)
        dockBottomConstraint = surfaceView.moveBottomDock(to: self)
        if keyboardDockGeometrySource == .systemLayoutGuide {
            keyboardLayoutGuide.followsUndockedKeyboard = true
            keyboardLayoutGuide.usesBottomSafeArea = true
            let guide = surfaceView.hostedBottomDockBottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor
            )
            guideDockConstraint = guide
            dockBottomConstraint.isActive = false
            guide.isActive = true
        }

        presentationBottomConstraint = terminalPresentationView.bottomAnchor.constraint(
            equalTo: surfaceView.hostedBottomDockTopAnchor
        )

        NSLayoutConstraint.activate([
            terminalClipView.topAnchor.constraint(equalTo: topAnchor),
            terminalClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalClipView.bottomAnchor.constraint(equalTo: surfaceView.hostedBottomDockTopAnchor),

            terminalPresentationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalPresentationView.widthAnchor.constraint(equalTo: widthAnchor),
            terminalPresentationView.heightAnchor.constraint(equalTo: heightAnchor),
            presentationBottomConstraint,

            surfaceView.topAnchor.constraint(equalTo: terminalPresentationView.topAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: terminalPresentationView.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: terminalPresentationView.trailingAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: terminalPresentationView.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        seatDockWithoutAnimation()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        syncDockSeatAuthority()
        syncPresentationReservation()
        if keyboardDockGeometrySource == .systemLayoutGuide {
            // Self-heal for transitions missed while detached (workspace
            // switches): the settled guide is the keyboard's live seat.
            surfaceView.setHostedKeyboardState(
                height: keyboardLayoutGuideOverlap,
                isVisible: nil
            )
        }
        if hostOwnsDockSeat {
            let reservation = surfaceView.hostedBottomReservation(
                keyboardHeight: surfaceView.hostedKeyboardHeight,
                bottomSafeAreaInset: resolvedBottomSafeAreaInset
            )
            if abs(dockBottomConstraint.constant + reservation) > 0.25 {
                dockBottomConstraint.constant = -reservation
            }
        }
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        seatDockWithoutAnimation()
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard window != nil,
              let transition = MobileKeyboardTransition(notification: notification) else { return }
        let targetHeight = max(0, transition.overlap(in: self))
        surfaceView.setHostedKeyboardState(
            height: targetHeight,
            isVisible: transition.isVisible(in: self)
        )
        guard hostOwnsDockSeat else {
            // The system guide retargets the dock inside UIKit's own keyboard
            // transaction; the wrapper and clip ride the same constraint pass.
            return
        }
        dockBottomConstraint.constant = -surfaceView.hostedBottomReservation(
            keyboardHeight: targetHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
        )
        transition.animate { [weak self] in
            self?.layoutIfNeeded()
        } completion: { [weak self] _ in
            self?.sampleTerminalDockPresentationGap()
        }
    }

    /// Whether the plain bottom constraint (not the system guide) seats the dock.
    private var hostOwnsDockSeat: Bool {
        keyboardDockGeometrySource == .keyboardNotifications || surfaceView.hostedChromeHidden
    }

    /// The chrome-hidden mode cannot ride the system guide (its safe-area
    /// fallback would float the invisible dock — and the render bottom — above
    /// the screen bottom), so hiding the chrome hands the seat to the plain
    /// constraint and showing it hands the seat back. Toggles happen outside
    /// keyboard animations, so the swap never retargets a moving leg.
    private func syncDockSeatAuthority() {
        guard let guideDockConstraint else { return }
        let wantsGuide = !surfaceView.hostedChromeHidden
        guard guideDockConstraint.isActive != wantsGuide else { return }
        if wantsGuide {
            dockBottomConstraint.isActive = false
            guideDockConstraint.isActive = true
        } else {
            guideDockConstraint.isActive = false
            dockBottomConstraint.constant = -surfaceView.hostedBottomReservation(
                keyboardHeight: surfaceView.hostedKeyboardHeight,
                bottomSafeAreaInset: resolvedBottomSafeAreaInset
            )
            dockBottomConstraint.isActive = true
        }
    }

    /// Keeps `renderWrapper.bottom == dock.top + reservation` seated on the
    /// CURRENT steady-state chrome band (composer band + toolbar + bottom safe
    /// area; zero while the chrome is hidden). The constant changes only on
    /// real chrome changes — composer growth, toolbar visibility, safe-area
    /// updates — never on keyboard motion, and a change made inside an
    /// animation block rides that animation's layout pass.
    private func syncPresentationReservation() {
        let reservation = surfaceView.hostedBottomChromeReservation
        guard abs(presentationBottomConstraint.constant - reservation) > 0.25 else { return }
        presentationBottomConstraint.constant = reservation
    }

    private func seatDockWithoutAnimation() {
        syncDockSeatAuthority()
        syncPresentationReservation()
        if hostOwnsDockSeat {
            dockBottomConstraint.constant = -surfaceView.hostedBottomReservation(
                keyboardHeight: surfaceView.hostedKeyboardHeight,
                bottomSafeAreaInset: resolvedBottomSafeAreaInset
            )
        }
        UIView.performWithoutAnimation {
            layoutIfNeeded()
        }
    }

    private var resolvedBottomSafeAreaInset: CGFloat {
        TerminalLetterboxGeometry.resolvedBottomSafeAreaInset(
            viewInset: safeAreaInsets.bottom,
            windowInset: window?.safeAreaInsets.bottom ?? 0
        )
    }

    private var keyboardLayoutGuideOverlap: CGFloat {
        guard bounds.height > 0 else { return 0 }
        let guideFrame = keyboardLayoutGuide.layoutFrame
        guard abs(guideFrame.maxY - bounds.maxY) <= 1 else {
            return surfaceView.hostedKeyboardHeight
        }
        let occupancy = max(0, bounds.maxY - guideFrame.minY)
        return occupancy > resolvedBottomSafeAreaInset + 0.5 ? occupancy : 0
    }

    func updateTerminalBackground(_ color: UIColor) {
        backgroundColor = color
        terminalClipView.backgroundColor = color
        terminalPresentationView.backgroundColor = color
    }

    func sampleTerminalDockPresentationGap() {
        #if DEBUG
        maximumTerminalDockPresentationGap = max(
            maximumTerminalDockPresentationGap,
            terminalDockPresentationGap
        )
        #endif
    }

    #if DEBUG
    var debugUsesNotificationKeyboardDock: Bool {
        keyboardDockGeometrySource == .keyboardNotifications
    }
    var debugKeyboardTargetHeight: CGFloat { surfaceView.hostedKeyboardHeight }
    var debugKeyboardTargetTop: CGFloat {
        surfaceView.hostedBottomDockFrame.maxY
    }
    var debugTerminalDockPresentationGap: CGFloat {
        terminalDockPresentationGap
    }
    var debugMaximumTerminalDockPresentationGap: CGFloat {
        maximumTerminalDockPresentationGap
    }

    /// The pixel seam between the render's bottom edge and the dock's top
    /// edge. Both derive from one constraint system laid out in one pass, so
    /// this must hold near zero on EVERY frame of every keyboard transition.
    private var terminalDockPresentationGap: CGFloat {
        guard let terminalBottom = surfaceView.hostedTerminalPresentationBottom(in: self),
              let dockTop = surfaceView.hostedBottomDockPresentationTop(in: self) else { return 0 }
        return abs(terminalBottom - dockTop)
    }
    #endif
}
#endif
