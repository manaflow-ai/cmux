#if canImport(UIKit)
import CmuxMobileDiagnostics
import CmuxMobileSupport
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// UIKit root that owns terminal clipping, dock placement, and keyboard motion.
///
/// Dock-following spine (from the keyboard-pinning rebuild, #10518): ONE
/// geometry authority — UIKit's keyboard frame notifications, on every OS
/// version — seats the dock-bottom constraint, `keyboardDidChangeFrame`
/// corrects a seat whose final frame disagrees with the `will` payload, and
/// ``MobileKeyboardFrameTracker`` (a process-wide screen-space keyboard
/// record) recovers transitions this host missed while detached (workspace
/// switches), including visibility, so a reattached toolbar toggle is never
/// stale. `UIKeyboardLayoutGuide` is deliberately not used: it misses
/// detached transitions, lies at the screen bottom on iOS 27, and forms a
/// second animation authority racing the notification-driven motion.
///
/// Terminal presentation (this PR): the grid never resizes for the keyboard
/// (see `TerminalLetterboxGeometry.terminalContainerSize`); the full-height
/// render pins with ONE constraint —
///
///     renderWrapper.bottom == dock.top + steadyBottomChromeReservation + slack
///
/// where `slack` is the blank-space absorption (`keyboardAbsorptionSlack`):
/// while the content bottom fits above the composer bar, blank rows absorb
/// the keyboard and the terminal stays top-pinned; as content grows the
/// render transitions continuously into the full bottom-pin. Both constants
/// retarget in one animated pass per keyboard leg, so a full-slack toggle
/// does not change the wrapper's frame at all. There is no settle-fold and no
/// presentation rebasing: with no grid renegotiation there is nothing to
/// mask, which is also why the rebuild-revert path selection collapsed to a
/// single presentation (the legacy transform and the rebuilt fold both
/// existed to hide the resize round-trip).
@MainActor
public final class GhosttySurfaceHostView: UIView {
    public let surfaceView: GhosttySurfaceView
    private let keyboardFrameTracker: MobileKeyboardFrameTracker
    private let terminalClipView = UIView()
    private let terminalPresentationView = UIView()
    /// dock.bottom == host.bottom + c; the sole dock seat authority.
    private var dockBottomConstraint: NSLayoutConstraint!
    /// renderWrapper.bottom == dock.top + steady chrome reservation + slack.
    private var presentationBottomConstraint: NSLayoutConstraint!
    /// Points of the keyboard intrusion currently absorbed by blank rows
    /// below the terminal content (see `syncPresentationReservation`).
    private var appliedAbsorptionSlack: CGFloat = 0
    /// True while a notification-driven keyboard leg is animating. Layout and
    /// display-link paths must not retarget the constants the leg owns.
    private var keyboardTransitionActive = false
    private var keyboardTransitionGeneration: UInt64 = 0
    #if DEBUG
    private var maximumTerminalDockPresentationGap: CGFloat = 0
    #endif

    /// Creates the host that owns terminal clipping, dock placement, and
    /// keyboard motion for one mounted surface.
    ///
    /// - Parameters:
    ///   - surfaceView: The terminal surface this host clips and docks.
    ///   - keyboardFrameTracker: The app-lifetime screen-space keyboard
    ///     record used to recover transitions this host missed while detached.
    ///   - keyboardDockRebuildRevertEnabled: Accepted for call-site
    ///     compatibility with the rebuild-revert kill switch shipped in
    ///     #10518. The keyboard-invariant grid removed the resize both of
    ///     that switch's presentations existed to mask, so one presentation
    ///     path remains and the value is not consulted.
    ///   - defaults: Accepted for call-site compatibility; not consulted.
    public init(
        surfaceView: GhosttySurfaceView,
        keyboardFrameTracker: MobileKeyboardFrameTracker,
        keyboardDockRebuildRevertEnabled: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        self.surfaceView = surfaceView
        self.keyboardFrameTracker = keyboardFrameTracker
        super.init(frame: surfaceView.frame)
        _ = keyboardDockRebuildRevertEnabled
        _ = defaults

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidChangeFrame(_:)),
            name: UIResponder.keyboardDidChangeFrameNotification,
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
            // A detach mid-leg must strip the in-flight Core Animation state
            // from every edge the leg was moving; a lingering presentation
            // animation would otherwise override the freshly seated
            // constraint model after reattachment until it expired.
            terminalPresentationView.layer.removeAllAnimations()
            terminalClipView.layer.removeAllAnimations()
            surfaceView.removeHostedBottomDockAnimations()
            return
        }
        keyboardTransitionGeneration &+= 1
        keyboardTransitionActive = false
        // Recover any keyboard transition that happened while detached: the
        // tracker records keyboard frames process-wide, so a workspace switch
        // that detached this host mid-transition cannot wedge the dock — or
        // the toolbar's keyboard-toggle state — at a stale seat.
        healKeyboardModelFromTracker()
        seatDockWithoutAnimation()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // A keyboard leg owns both constants until its animation completes;
        // layout passes inside the leg must not reseat them.
        guard !keyboardTransitionActive else { return }
        // Re-derive the seat from the tracker whenever this host is laid out
        // OUTSIDE a keyboard transition. A keyboard notification can arrive
        // while the host still has pre-layout bounds (a scene whose chrome is
        // settling); the overlap captured then goes stale the moment the
        // host's own frame changes, and no further keyboard event would ever
        // correct the seat.
        healKeyboardModelFromTracker()
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
        // The grid container reads the window's bottom inset through the
        // surface's fallback resolver; the surface itself cannot observe a
        // window-level inset change (its own inset stays 0 while slid), so
        // the host forwards the resync.
        surfaceView.hostRequestsGeometrySync()
    }

    /// Folds the tracker's process-wide keyboard record into the surface
    /// model (height AND visibility) when it disagrees. The tracker hears the
    /// same notifications this host does, in the same synchronous post, so an
    /// attached toggle is always leg-owned before any layout pass runs — this
    /// only corrects state from transitions the host missed while detached or
    /// captured against stale bounds.
    private func healKeyboardModelFromTracker() {
        guard let overlap = keyboardFrameTracker.currentOverlap(in: self) else { return }
        surfaceView.setHostedKeyboardState(
            height: max(0, overlap),
            isVisible: keyboardFrameTracker.currentVisibility(in: self)
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard window != nil,
              let transition = MobileKeyboardTransition(notification: notification) else { return }
        beginKeyboardLeg(
            targetHeight: max(0, transition.overlap(in: self)),
            targetIsVisible: transition.isVisible(in: self),
            transition: transition
        )
    }

    /// Corrects the seat when the keyboard's final frame disagrees with the
    /// last `will` payload (UIKit re-seats a keyboard whose layout changed
    /// mid-presentation, e.g. an autocorrect bar toggling with the responder).
    ///
    /// A `did` that AGREES with the current model is ignored entirely: acting
    /// on it would replace an in-flight leg with a zero-duration relayout and
    /// snap the dock (the historical re-open glitch). Disagreements run the
    /// normal leg with a short curve because `did` payloads carry no
    /// animation duration of their own.
    @objc private func keyboardDidChangeFrame(_ notification: Notification) {
        guard window != nil,
              let transition = MobileKeyboardTransition(notification: notification) else { return }
        let targetHeight = max(0, transition.overlap(in: self))
        guard abs(targetHeight - surfaceView.hostedKeyboardHeight) > 0.5 else { return }
        beginKeyboardLeg(
            targetHeight: targetHeight,
            targetIsVisible: transition.isVisible(in: self),
            transition: transition,
            durationOverride: transition.duration > 0 ? nil : 0.2
        )
    }

    private func beginKeyboardLeg(
        targetHeight: CGFloat,
        targetIsVisible: Bool,
        transition: MobileKeyboardTransition,
        durationOverride: TimeInterval? = nil
    ) {
        if targetHeight > 0 {
            // Refresh the blank-band measurement immediately: content written
            // or cleared just before this raise (with no output since) must
            // not steer the absorption with a stale row count. The result
            // lands mid-leg and the display-link follow applies any
            // correction right at settle.
            surfaceView.refreshHostedContentBottomNow()
        }
        surfaceView.setHostedKeyboardState(
            height: targetHeight,
            isVisible: targetIsVisible
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
        transition.animate(durationOverride: durationOverride) { [weak self] in
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
