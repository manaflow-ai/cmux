#if canImport(UIKit)
import CmuxMobileDiagnostics
import CmuxMobileSupport
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// UIKit root that owns terminal clipping, dock placement, and keyboard motion.
///
/// Dock seat: `UIKeyboardLayoutGuide` wherever it is trustworthy (chrome
/// visible, non-iOS-27). iOS keyboards animate with a private spring that
/// notification-driven followers can only approximate — dogfood consistently
/// rated the guide-seated composer bar as "stuck to the keyboard the whole
/// way" while the notification approximation reads duller — so the bar rides
/// UIKit's own keyboard transaction, pixel-locked. On iOS 27 (where the
/// guide can lie at the screen bottom) and while the chrome is hidden (the
/// guide's safe-area fallback cannot seat an invisible dock flush with the
/// screen edge), the seat falls back to the notification-driven constant
/// from the keyboard-pinning rebuild (#10518), with `keyboardDidChangeFrame`
/// disagreement reseats. ``MobileKeyboardFrameTracker`` heals the keyboard
/// MODEL (height and visibility, for the toolbar toggle and diagnostics)
/// after transitions missed while detached, on every OS.
///
/// Terminal presentation: the grid never resizes for the keyboard (see
/// `TerminalLetterboxGeometry.terminalContainerSize`); the full-height
/// render pins through STATIC inequalities —
///
///     renderWrapper.bottom <= host.bottom                    (natural cap)
///     renderWrapper.bottom <= dock.top + chrome + blank      (content cap)
///     renderWrapper.bottom == host.bottom   (optional pull, priority 750)
///
/// so the solver keeps the wrapper as low as the caps allow: while the
/// content bottom fits above the composer bar the natural cap binds (the
/// keyboard covers only blank rows) and while it does not, the content cap
/// binds and the render rides the dock. NOTHING retargets during a keyboard
/// leg — the caps are keyboard-independent, so the wrapper's target comes
/// out of the SAME layout solve and animation transaction that moves the
/// dock, whichever authority is seating it. `chrome` and `blank` change only
/// on chrome mutations and content measurements. There is no settle-fold and
/// no presentation rebasing: with no grid renegotiation there is nothing to
/// mask.
@MainActor
public final class GhosttySurfaceHostView: UIView {
    public let surfaceView: GhosttySurfaceView
    private let keyboardFrameTracker: MobileKeyboardFrameTracker
    private let terminalClipView = UIView()
    private let terminalPresentationView = UIView()
    /// dock.bottom == host.bottom + c; the seat authority on iOS 27 and while
    /// the chrome is hidden.
    private var dockBottomConstraint: NSLayoutConstraint!
    /// dock.bottom == keyboardLayoutGuide.top; the seat authority everywhere
    /// the guide is trustworthy (pixel-locked to the keyboard's own spring).
    private var guideDockConstraint: NSLayoutConstraint?
    /// renderWrapper.bottom <= dock.top + chrome + blank + reveal (the
    /// content cap).
    private var presentationContentCapConstraint: NSLayoutConstraint!
    /// The blank measurement currently baked into the content cap.
    private var appliedBlankBelowContent: CGFloat = 0
    /// The scroll-top reveal currently baked into the content cap: how far
    /// the pixel-scroll axis has slid the render back down past
    /// scrollback-top so the keyboard-up presentation's clipped top rows are
    /// visible. Follows the gesture through the display-link refresh.
    private var appliedScrollTopReveal: CGFloat = 0
    /// True while a notification-driven keyboard leg is animating. Layout and
    /// display-link paths must not retarget the constant the leg owns.
    private var keyboardTransitionActive = false
    private var keyboardTransitionGeneration: UInt64 = 0
    /// Whether this host seats the dock on the system keyboard guide.
    /// False on iOS 27 (the guide can lie at the screen bottom), when the
    /// remote `ios-keyboard-dock-rebuild-revert` kill switch routes devices
    /// to the notification seat, and under the DEBUG rebuild forces (UI-test
    /// env or the Settings > Developer override) so CI simulators can
    /// exercise the notification path end to end.
    private let usesKeyboardGuideSeat: Bool
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
    ///   - keyboardDockRebuildRevertEnabled: The remote
    ///     `ios-keyboard-dock-rebuild-revert` kill switch, snapshotted at
    ///     mount; `true` seats the dock from keyboard notifications instead
    ///     of the system guide on iOS ≤26 (the presentation itself is one
    ///     path either way — only the seat authority changes).
    ///   - defaults: The store consulted for the DEBUG-only Developer
    ///     override; production callers use `.standard`, tests inject a
    ///     scoped suite.
    public init(
        surfaceView: GhosttySurfaceView,
        keyboardFrameTracker: MobileKeyboardFrameTracker,
        keyboardDockRebuildRevertEnabled: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        self.surfaceView = surfaceView
        self.keyboardFrameTracker = keyboardFrameTracker
        var debugForceLegacy = false
        var debugForceRebuild = false
        #if DEBUG
        debugForceLegacy = UITestConfig.forceLegacyKeyboardDock
        debugForceRebuild = UITestConfig.forceRebuildKeyboardDock
            || defaults.bool(forKey: "cmux.mobile.debug.forceRebuildKeyboardDock.v1")
        #else
        _ = defaults
        #endif
        // "Legacy" retains its pre-#10518 meaning: the guide-seated dock.
        // Any rebuild force or the remote kill switch selects the
        // notification seat; iOS 27 always uses it (the guide lies there).
        if debugForceLegacy {
            usesKeyboardGuideSeat = true
        } else if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            usesKeyboardGuideSeat = false
        } else if debugForceRebuild || keyboardDockRebuildRevertEnabled {
            usesKeyboardGuideSeat = false
        } else {
            usesKeyboardGuideSeat = true
        }
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
        if usesKeyboardGuideSeat {
            keyboardLayoutGuide.followsUndockedKeyboard = true
            keyboardLayoutGuide.usesBottomSafeArea = true
            let guide = surfaceView.hostedBottomDockBottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor
            )
            guideDockConstraint = guide
            dockBottomConstraint.isActive = false
            guide.isActive = true
        }

        presentationContentCapConstraint = terminalPresentationView.bottomAnchor.constraint(
            lessThanOrEqualTo: surfaceView.hostedBottomDockTopAnchor
        )
        // Optional pull: the solver keeps the wrapper as low as the caps
        // allow, so the natural position wins whenever the blank band can
        // absorb the whole intrusion and the content cap wins otherwise —
        // the min() the absorption wants, with zero per-leg retargeting.
        let naturalPull = terminalPresentationView.bottomAnchor.constraint(equalTo: bottomAnchor)
        naturalPull.priority = .defaultHigh

        NSLayoutConstraint.activate([
            terminalClipView.topAnchor.constraint(equalTo: topAnchor),
            terminalClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalClipView.bottomAnchor.constraint(equalTo: surfaceView.hostedBottomDockTopAnchor),

            terminalPresentationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalPresentationView.widthAnchor.constraint(equalTo: widthAnchor),
            terminalPresentationView.heightAnchor.constraint(equalTo: heightAnchor),
            terminalPresentationView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            presentationContentCapConstraint,
            naturalPull,

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
        // A notification-driven keyboard leg owns the dock constant until its
        // animation completes; layout passes inside the leg must not reseat it.
        guard !keyboardTransitionActive else { return }
        // Re-derive the keyboard MODEL from the tracker whenever this host is
        // laid out outside a keyboard transition: a notification can arrive
        // while the host still has pre-layout bounds, and the overlap captured
        // then goes stale the moment the host's own frame changes.
        healKeyboardModelFromTracker()
        syncDockSeatAuthority()
        syncPresentationCaps()
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

    /// Whether the plain bottom constraint (not the system guide) seats the
    /// dock: always on iOS 27, and while the chrome is hidden on any OS (the
    /// guide's safe-area fallback would float the invisible dock — and the
    /// render bottom with it — above the screen edge).
    private var hostOwnsDockSeat: Bool {
        !usesKeyboardGuideSeat || surfaceView.hostedChromeHidden
    }

    /// Chrome toggles happen outside keyboard animations, so the authority
    /// swap never retargets a moving leg.
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
            // lands mid-leg through the content cap's own short ease.
            surfaceView.refreshHostedContentBottomNow()
        }
        surfaceView.setHostedKeyboardState(
            height: targetHeight,
            isVisible: targetIsVisible
        )
        // Every keyboard leg drops the scroll-top reveal: it was granted
        // against the OLD keyboard's clipped-top budget, and holding it
        // across a raise would cover the newest rows without the user ever
        // scrolling away from them. The cap reseat below lands in the same
        // solve (and animation transaction) as the dock motion, so the
        // wrapper travels once, not twice.
        surfaceView.clearHostedScrollTopReveal()
        syncPresentationCaps()
        #if DEBUG
        maximumTerminalDockPresentationGap = 0
        #endif
        MobileDebugLog.anchormux(
            "kb.leg target=\(Int(targetHeight)) guideSeat=\(hostOwnsDockSeat ? 0 : 1) "
            + "blank=\(Int(appliedBlankBelowContent)) wrapY=\(Int(terminalPresentationView.frame.minY))"
        )
        guard hostOwnsDockSeat else {
            // The system guide moves the dock inside UIKit's own keyboard
            // transaction, pixel-locked to the keyboard's spring; the caps
            // are keyboard-independent, so the wrapper's new frame comes out
            // of that same transaction. Nothing to retarget or animate here.
            return
        }
        keyboardTransitionGeneration &+= 1
        let generation = keyboardTransitionGeneration
        keyboardTransitionActive = true
        dockBottomConstraint.constant = -surfaceView.hostedBottomReservation(
            keyboardHeight: targetHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
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

    /// Keeps the content cap seated on the CURRENT chrome band, blank
    /// measurement, and scroll-top reveal:
    /// `wrapper.bottom <= dock.top + chrome + blank + reveal`. All terms are
    /// keyboard-independent (a keyboard leg clears the reveal before it
    /// animates), so the cap never changes during a keyboard leg — the
    /// wrapper's target always comes out of the same layout solve (and
    /// animation transaction) that moves the dock.
    private func syncPresentationCaps() {
        let blank = surfaceView.hostedBlankBelowContent ?? 0
        let reveal = surfaceView.hostedScrollTopReveal
        appliedBlankBelowContent = blank
        appliedScrollTopReveal = reveal
        let constant = surfaceView.hostedBottomChromeReservation + blank + reveal
        guard abs(presentationContentCapConstraint.constant - constant) > 0.25 else { return }
        MobileDebugLog.anchormux(
            "kb.reseat capC=\(Int(presentationContentCapConstraint.constant))->\(Int(constant)) "
            + "blank=\(Int(blank)) reveal=\(Int(reveal)) kb=\(Int(surfaceView.hostedKeyboardHeight))"
        )
        presentationContentCapConstraint.constant = constant
    }

    /// Content follow while a keyboard is up: content written under the
    /// keyboard consumes the blank band, so the content cap tightens and the
    /// render slides just enough to keep the content bottom above the
    /// composer bar (and relaxes after a `clear`); and the pixel-scroll axis
    /// grants or consumes the scroll-top reveal, sliding the render so the
    /// clipped top rows track the gesture. Driven by the surface's display
    /// link; a no-op within half a point. Measurement changes ease over
    /// 0.2s; while a scroll gesture (or its deceleration) owns the axis the
    /// retarget is UNANIMATED so the render tracks the finger frame-locked,
    /// exactly like the grid scroll it continues.
    func refreshKeyboardAbsorptionIfNeeded() {
        guard !keyboardTransitionActive,
              surfaceView.hostedKeyboardHeight > 0 else { return }
        let blank = surfaceView.hostedBlankBelowContent ?? 0
        let reveal = surfaceView.hostedScrollTopReveal
        guard abs(blank - appliedBlankBelowContent) > 0.5
                || abs(reveal - appliedScrollTopReveal) > 0.5 else { return }
        appliedBlankBelowContent = blank
        appliedScrollTopReveal = reveal
        let constant = surfaceView.hostedBottomChromeReservation + blank + reveal
        if surfaceView.scrollInteractionActive {
            UIView.performWithoutAnimation {
                self.presentationContentCapConstraint.constant = constant
                self.layoutIfNeeded()
            }
            return
        }
        MobileDebugLog.anchormux(
            "kb.follow capC->\(Int(constant)) blank=\(Int(blank)) reveal=\(Int(reveal)) "
            + "kb=\(Int(surfaceView.hostedKeyboardHeight))"
        )
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.presentationContentCapConstraint.constant = constant
            self.layoutIfNeeded()
        }
    }

    private func seatDockWithoutAnimation() {
        syncDockSeatAuthority()
        syncPresentationCaps()
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
    var debugUsesNotificationKeyboardDock: Bool { hostOwnsDockSeat }
    /// The expected render-to-dock seam for the CURRENT state: how much of
    /// the live intrusion the blank band absorbs, plus the scroll-top reveal
    /// the pixel-scroll axis has granted (both legitimately detach the
    /// render bottom from the dock top). Mirrors what the inequality system
    /// produces, for the probe's gap == slack contract.
    var debugKeyboardAbsorptionSlack: CGFloat {
        let inset = resolvedBottomSafeAreaInset
        let intrusion = max(
            0,
            surfaceView.hostedBottomReservation(
                keyboardHeight: surfaceView.hostedKeyboardHeight,
                bottomSafeAreaInset: inset
            ) - surfaceView.hostedBottomReservation(keyboardHeight: 0, bottomSafeAreaInset: inset)
        )
        return TerminalLetterboxGeometry.keyboardAbsorptionSlack(
            blankBelowContent: appliedBlankBelowContent,
            intrusion: intrusion
        ) + appliedScrollTopReveal
    }
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
