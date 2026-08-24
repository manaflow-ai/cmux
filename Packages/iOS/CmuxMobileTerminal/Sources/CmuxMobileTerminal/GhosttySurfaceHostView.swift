#if canImport(UIKit)
import CmuxMobileDiagnostics
import CmuxMobileSupport
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// UIKit root that owns terminal clipping, dock placement, and keyboard motion.
///
/// The terminal grid never resizes for the keyboard (see
/// `TerminalLetterboxGeometry.terminalContainerSize`): the render always has
/// its full keyboard-down height, and this host pins its bottom edge with ONE
/// constraint —
///
///     renderWrapper.bottom == dock.top + steadyBottomChromeReservation + slack
///
/// where `slack` is the blank-space absorption (`keyboardAbsorptionSlack`):
/// while the content bottom fits above the composer bar, the blank rows below
/// it absorb the keyboard and the terminal stays top-pinned; as content grows
/// the render transitions continuously into the full bottom-pin.
///
/// ONE animation authority: keyboard notifications retarget the dock-bottom
/// constant and the slack constant together and run a single animated layout
/// pass with the keyboard's own curve. `UIKeyboardLayoutGuide` deliberately
/// does NOT seat the dock: the guide animates inside UIKit's own transaction,
/// and pairing it with a notification-driven slack retarget produced two
/// racing timelines — the render visibly travelled on keyboard toggles even
/// when the two changes cancel exactly (top-pinned short content). With both
/// constants in one pass, a full-slack toggle does not move the wrapper's
/// frame at all. The guide remains attached as a PASSIVE SENSOR: its settled
/// frame self-heals the keyboard model after transitions missed while
/// detached (workspace switches). iOS 27 can seat the guide at the screen
/// bottom while the keyboard is visible, so the sensor is disabled there.
@MainActor
public final class GhosttySurfaceHostView: UIView {
    public let surfaceView: GhosttySurfaceView
    private let terminalClipView = UIView()
    private let terminalPresentationView = UIView()
    /// dock.bottom == host.bottom + c; the sole dock seat authority.
    private var dockBottomConstraint: NSLayoutConstraint!
    /// renderWrapper.bottom == dock.top + steady chrome reservation + slack.
    private var presentationBottomConstraint: NSLayoutConstraint!
    /// Points of the keyboard intrusion currently absorbed by blank rows
    /// below the terminal content (see `syncPresentationReservation`).
    private var appliedAbsorptionSlack: CGFloat = 0
    /// True while a notification-driven keyboard leg is animating. The
    /// keyboard-guide SENSOR must not publish mid-flight guide frames into
    /// the model then (it lags the notification and re-poisons the settled
    /// target — the "content dips, then heals" glitch), and the layout /
    /// display-link paths must not retarget the constants the leg owns.
    private var keyboardTransitionActive = false
    private var keyboardTransitionGeneration: UInt64 = 0
    /// Forces the passive `keyboardLayoutGuide` to RESOLVE: an unconstrained
    /// layout guide never updates its `layoutFrame`, which silently turned
    /// the sensor into a stale-model echo. Hidden, zero-sized, and nothing
    /// else depends on it, so it cannot become a second animation authority.
    private let keyboardGuideResolutionProbe = UIView()
    /// Whether the settled keyboard layout guide may self-heal the keyboard
    /// model (false on iOS 27, where the guide can lie at the screen bottom).
    private let usesKeyboardGuideSensor: Bool = {
        #if DEBUG
        if UITestConfig.forceIOS27KeyboardDockWorkaround { return false }
        #endif
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 27
    }()
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
        if usesKeyboardGuideSensor {
            // Sensor only — the dock does not constrain to the guide.
            // Configured so its layoutFrame tracks the keyboard the way the
            // dock semantics do, with a hidden zero-sized probe riding its
            // top edge so UIKit actually resolves the guide's frame.
            keyboardLayoutGuide.followsUndockedKeyboard = true
            keyboardLayoutGuide.usesBottomSafeArea = true
            keyboardGuideResolutionProbe.isHidden = true
            keyboardGuideResolutionProbe.isUserInteractionEnabled = false
            keyboardGuideResolutionProbe.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keyboardGuideResolutionProbe)
            NSLayoutConstraint.activate([
                keyboardGuideResolutionProbe.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                keyboardGuideResolutionProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
                keyboardGuideResolutionProbe.widthAnchor.constraint(equalToConstant: 0),
                keyboardGuideResolutionProbe.heightAnchor.constraint(equalToConstant: 0),
            ])
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
        guard window != nil else {
            keyboardTransitionGeneration &+= 1
            keyboardTransitionActive = false
            return
        }
        keyboardTransitionGeneration &+= 1
        keyboardTransitionActive = false
        seatDockWithoutAnimation()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // A keyboard leg owns both constants until its animation completes;
        // layout passes inside the leg must not reseat them.
        guard !keyboardTransitionActive else { return }
        if usesKeyboardGuideSensor {
            // Self-heal for transitions missed while detached (workspace
            // switches): the settled guide is the keyboard's live seat. The
            // VISIBILITY heals too — the model lives on the (persistent)
            // surface, so a dismissal that happened while this host was
            // detached leaves it stuck at "visible" and the toolbar's
            // keyboard toggle opens a fresh workspace in the wrong state,
            // needing two taps. A settled guide at the screen bottom is an
            // authoritative "keyboard down" on the OS versions the sensor
            // runs on.
            let overlap = keyboardLayoutGuideOverlap
            surfaceView.setHostedKeyboardState(
                height: overlap,
                isVisible: overlap > 0.5
            )
        }
        syncPresentationReservation()
        let reservation = surfaceView.hostedBottomReservation(
            keyboardHeight: surfaceView.hostedKeyboardHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
        )
        if abs(dockBottomConstraint.constant + reservation) > 0.25 {
            dockBottomConstraint.constant = -reservation
        }
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        guard !keyboardTransitionActive else { return }
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
        #if DEBUG
        maximumTerminalDockPresentationGap = 0
        #endif
        keyboardTransitionGeneration &+= 1
        let generation = keyboardTransitionGeneration
        keyboardTransitionActive = true
        // Both constants retarget in ONE animated pass. When the slack equals
        // the whole intrusion (short content) they cancel exactly and the
        // wrapper frame does not change — the layout pass animates nothing.
        let intrusion = keyboardIntrusion(forHeight: targetHeight)
        let blank = surfaceView.hostedBlankBelowContent
        appliedAbsorptionSlack = TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: blank,
            intrusion: intrusion
        )
        presentationBottomConstraint.constant =
            surfaceView.hostedBottomChromeReservation + appliedAbsorptionSlack
        dockBottomConstraint.constant = -surfaceView.hostedBottomReservation(
            keyboardHeight: targetHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
        )
        MobileDebugLog.anchormux(
            "kb.leg gen=\(generation) target=\(Int(targetHeight)) intrusion=\(Int(intrusion)) "
            + "blank=\(blank.map { String(Int($0)) } ?? "nil") slack=\(Int(appliedAbsorptionSlack)) "
            + "presC=\(Int(presentationBottomConstraint.constant)) dockC=\(Int(dockBottomConstraint.constant)) "
            + "wrapY=\(Int(terminalPresentationView.frame.minY))"
        )
        transition.animate { [weak self] in
            self?.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.keyboardTransitionGeneration == generation else { return }
            self.keyboardTransitionActive = false
            MobileDebugLog.anchormux(
                "kb.leg.done gen=\(generation) wrapY=\(Int(self.terminalPresentationView.frame.minY)) "
                + "dockTop=\(Int(self.surfaceView.hostedBottomDockFrame.minY))"
            )
            self.sampleTerminalDockPresentationGap()
        }
    }

    /// Keeps `renderWrapper.bottom == dock.top + reservation + slack` seated
    /// for the CURRENT model state; used by non-animated paths (plain layout,
    /// window attach, safe-area changes). Keyboard transitions retarget the
    /// constant themselves so both edges share one animated pass.
    private func syncPresentationReservation() {
        let slack = currentAbsorptionSlack()
        appliedAbsorptionSlack = slack
        let constant = surfaceView.hostedBottomChromeReservation + slack
        guard abs(presentationBottomConstraint.constant - constant) > 0.25 else { return }
        MobileDebugLog.anchormux(
            "kb.reseat presC=\(Int(presentationBottomConstraint.constant))->\(Int(constant)) "
            + "slack=\(Int(slack)) kb=\(Int(surfaceView.hostedKeyboardHeight))"
        )
        presentationBottomConstraint.constant = constant
    }

    /// The blank-space absorption for the CURRENT keyboard model state.
    private func currentAbsorptionSlack() -> CGFloat {
        TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: surfaceView.hostedBlankBelowContent,
            intrusion: keyboardIntrusion(forHeight: surfaceView.hostedKeyboardHeight)
        )
    }

    /// How far the dock top sits above its keyboard-down seat for a keyboard
    /// of `height`: the reservation delta between the live keyboard and the
    /// steady state, in the current chrome mode.
    private func keyboardIntrusion(forHeight height: CGFloat) -> CGFloat {
        let inset = resolvedBottomSafeAreaInset
        return max(
            0,
            surfaceView.hostedBottomReservation(keyboardHeight: height, bottomSafeAreaInset: inset)
                - surfaceView.hostedBottomReservation(keyboardHeight: 0, bottomSafeAreaInset: inset)
        )
    }

    /// Per-frame follow while a keyboard is up: content written under the
    /// keyboard consumes the blank band, so the slack shrinks and the render
    /// slides just enough to keep the content bottom above the composer bar
    /// (and re-expands after a `clear`). Driven by the surface's display
    /// link; a no-op within half a point.
    func refreshKeyboardAbsorptionIfNeeded() {
        guard !keyboardTransitionActive,
              surfaceView.hostedKeyboardHeight > 0 else { return }
        let slack = currentAbsorptionSlack()
        guard abs(slack - appliedAbsorptionSlack) > 0.5 else { return }
        appliedAbsorptionSlack = slack
        let constant = surfaceView.hostedBottomChromeReservation + slack
        MobileDebugLog.anchormux(
            "kb.follow presC->\(Int(constant)) slack=\(Int(slack)) kb=\(Int(surfaceView.hostedKeyboardHeight))"
        )
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.presentationBottomConstraint.constant = constant
            self.layoutIfNeeded()
        }
    }

    private func seatDockWithoutAnimation() {
        syncPresentationReservation()
        dockBottomConstraint.constant = -surfaceView.hostedBottomReservation(
            keyboardHeight: surfaceView.hostedKeyboardHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
        )
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
    var debugUsesNotificationKeyboardDock: Bool { true }
    var debugKeyboardAbsorptionSlack: CGFloat { appliedAbsorptionSlack }
    var debugTerminalDockPresentationGap: CGFloat {
        terminalDockPresentationGap
    }
    var debugMaximumTerminalDockPresentationGap: CGFloat {
        maximumTerminalDockPresentationGap
    }

    /// The pixel seam between the render's bottom edge and the dock's top
    /// edge. Both derive from one constraint system laid out in one pass, so
    /// on every frame of every keyboard transition this must equal the
    /// blank-space absorption slack (zero whenever content reaches the
    /// composer bar).
    private var terminalDockPresentationGap: CGFloat {
        guard let terminalBottom = surfaceView.hostedTerminalPresentationBottom(in: self),
              let dockTop = surfaceView.hostedBottomDockPresentationTop(in: self) else { return 0 }
        return abs(terminalBottom - dockTop)
    }
    #endif
}
#endif
