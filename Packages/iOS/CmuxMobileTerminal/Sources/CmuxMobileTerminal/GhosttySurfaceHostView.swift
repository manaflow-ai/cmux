#if canImport(UIKit)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import QuartzCore
import UIKit

/// UIKit root that owns terminal clipping, dock placement, and keyboard motion.
///
/// One geometry authority — UIKit's keyboard frame notifications, on every OS
/// version — drives two constraint constants per keyboard leg: the dock-bottom
/// offset and the render wrapper's bottom offset. Every other moving edge (the
/// clip boundary, toolbar, composer band) derives from those inside a single
/// animated `layoutIfNeeded()` running the keyboard's own curve, so the bars
/// and the terminal boundary cannot land on different timelines. An
/// interrupted reversal is just new constants plus another animated layout
/// pass: `.beginFromCurrentState` retargets every layer from its live
/// presentation frame in the same transaction, which is why no
/// presentation-layer rebasing exists anywhere in this file.
///
/// `UIKeyboardLayoutGuide` is deliberately not used: it misses transitions
/// that happen while the view is detached (workspace switches), it can seat at
/// the screen bottom while the keyboard is visible on iOS 27, and it forms a
/// second animation authority racing the notification-driven renderer motion.
/// Detached-transition recovery comes from ``MobileKeyboardFrameTracker``,
/// which records keyboard frames process-wide.
///
/// The Metal surface remains full-size and unchanged behind
/// ``terminalClipView`` until the transition settles; the wrapper's animated
/// endpoint is the exact render-bottom edge the first settled layout pass will
/// compute, so folding the settled position into the renderer model is a
/// visual no-op.
@MainActor
public final class GhosttySurfaceHostView: UIView {
    public let surfaceView: GhosttySurfaceView
    private let keyboardFrameTracker: MobileKeyboardFrameTracker
    /// The legacy notification+transform path is the shipping default on
    /// every OS (dogfood rated it above the rebuild, and iOS 27's keyboard
    /// APIs misreport frames under the rebuilt path). The rebuilt
    /// single-constraint path stays reachable on iOS ≤26 only, through the
    /// remote `ios-keyboard-dock-rebuild-revert` kill switch or the
    /// DEBUG-only local overrides; ``TerminalKeyboardDockPathSelection``
    /// owns that precedence.
    private let usesLegacyKeyboardDockPath: Bool
    private let terminalClipView = UIView()
    private let terminalPresentationView = UIView()
    private var dockBottomConstraint: NSLayoutConstraint!
    private var presentationBottomConstraint: NSLayoutConstraint!
    private var keyboardTransitionGeneration: UInt64 = 0
    private var keyboardTransitionActive = false
    private var keyboardTargetHeight: CGFloat = 0
    private var keyboardTargetTop: CGFloat = 0
    private var keyboardTargetRenderBottom: CGFloat = 0
    #if DEBUG
    private var maximumTerminalDockPresentationGap: CGFloat = 0
    private var maximumRendererDockPresentationGap: CGFloat = 0
    #endif

    /// Creates the host that owns terminal clipping, dock placement, and
    /// keyboard motion for one mounted surface.
    ///
    /// - Parameters:
    ///   - surfaceView: The terminal surface this host clips and docks.
    ///   - keyboardFrameTracker: The app-lifetime screen-space keyboard
    ///     record used to recover transitions this host missed while detached.
    ///   - keyboardDockRebuildRevertEnabled: The remote
    ///     `ios-keyboard-dock-rebuild-revert` kill switch value, snapshotted
    ///     at mount; `true` routes iOS ≤26 to the rebuilt dock path.
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
        // UI-test env force, or the Settings > Developer dogfood override
        // (per-host snapshot: applies to terminals hosted after it changes).
        debugForceRebuild = UITestConfig.forceRebuildKeyboardDock
            || defaults.cmuxForceRebuildKeyboardDock
        #endif
        self.usesLegacyKeyboardDockPath = TerminalKeyboardDockPathSelection(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            remoteRebuildRevert: keyboardDockRebuildRevertEnabled,
            debugForceLegacy: debugForceLegacy,
            debugForceRebuild: debugForceRebuild
        ).usesLegacyPath
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
        presentationBottomConstraint = terminalPresentationView.bottomAnchor.constraint(
            equalTo: bottomAnchor
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
            presentationBottomConstraint.constant = 0
            terminalPresentationView.transform = .identity
            terminalPresentationView.layer.removeAllAnimations()
            terminalClipView.layer.removeAllAnimations()
            surfaceView.removeHostedKeyboardMotionAnimations()
            return
        }
        guard !keyboardTransitionActive else { return }
        // Recover any keyboard transition that happened while detached: the
        // tracker records keyboard frames process-wide, so a workspace switch
        // that detached this host mid-transition cannot wedge the dock at its
        // stale pre-detach seat. Both paths recover — keyboard notifications
        // are ignored while detached, so the last notification-derived height
        // is exactly the value that goes stale.
        if let overlap = keyboardFrameTracker.currentOverlap(in: self) {
            keyboardTargetHeight = max(0, overlap)
        }
        settleDockWithoutKeyboardAnimation()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        guard !keyboardTransitionActive else { return }
        settleDockWithoutKeyboardAnimation()
    }

    /// Re-derives the dock seat from the tracker's keyboard record whenever this
    /// host is laid out OUTSIDE a keyboard transition. A keyboard notification
    /// can arrive while the host still has pre-layout bounds (a scene whose
    /// chrome is settling); the overlap captured then goes stale the moment the
    /// host's own frame changes, and no further keyboard event would ever
    /// correct the seat. The guide-based design self-healed here implicitly;
    /// the notification authority must do it explicitly.
    public override func layoutSubviews() {
        super.layoutSubviews()
        guard !usesLegacyKeyboardDockPath,
              !keyboardTransitionActive,
              let overlap = keyboardFrameTracker.currentOverlap(in: self) else { return }
        let nextHeight = max(0, overlap)
        let reservation = surfaceView.hostedBottomReservation(
            keyboardHeight: nextHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
        )
        guard abs(nextHeight - keyboardTargetHeight) > 0.5
            || abs(dockBottomConstraint.constant + reservation) > 0.5 else { return }
        keyboardTargetHeight = nextHeight
        dockBottomConstraint.constant = -reservation
        surfaceView.settleHostedKeyboard(
            height: nextHeight,
            isVisible: keyboardFrameTracker.currentVisibility(in: self)
        )
        keyboardTargetTop = max(0, bounds.maxY - reservation)
        keyboardTargetRenderBottom = surfaceView.hostedTerminalRenderBottom
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard window != nil,
              let transition = MobileKeyboardTransition(notification: notification) else { return }
        beginKeyboardTransition(
            targetHeight: transition.overlap(in: self),
            targetIsVisible: transition.isVisible(in: self),
            transition: transition
        )
    }

    /// Corrects the seat when the keyboard's final frame disagrees with the
    /// last `will` payload (UIKit re-seats a keyboard whose layout changed
    /// mid-presentation, e.g. an autocorrect bar toggling with the responder).
    ///
    /// A `did` that AGREES with the current target is ignored entirely: acting
    /// on it would replace an in-flight leg with a zero-duration relayout and
    /// snap the dock (the historical re-open glitch). Disagreements run the
    /// normal transition path with a short curve because `did` payloads carry
    /// no animation duration of their own.
    @objc private func keyboardDidChangeFrame(_ notification: Notification) {
        guard !usesLegacyKeyboardDockPath,
              window != nil,
              let transition = MobileKeyboardTransition(notification: notification) else { return }
        let targetHeight = max(0, transition.overlap(in: self))
        guard abs(targetHeight - keyboardTargetHeight) > 0.5 else { return }
        beginKeyboardTransition(
            targetHeight: targetHeight,
            targetIsVisible: transition.isVisible(in: self),
            transition: transition,
            durationOverride: transition.duration > 0 ? nil : 0.2
        )
    }

    private func beginKeyboardTransition(
        targetHeight: CGFloat,
        targetIsVisible: Bool,
        transition: MobileKeyboardTransition,
        durationOverride: TimeInterval? = nil
    ) {
        if usesLegacyKeyboardDockPath {
            beginLegacyKeyboardTransition(
                targetHeight: targetHeight,
                targetIsVisible: targetIsVisible,
                transition: transition
            )
            return
        }
        keyboardTransitionGeneration &+= 1
        let generation = keyboardTransitionGeneration
        keyboardTransitionActive = true
        // Flush layout that predates this keyboard leg so the animated pass
        // below carries only keyboard motion. The transition flag is already
        // set: the tracker observed this same notification first, so an
        // unguarded flush would let the layout self-heal seat the dock at the
        // new target instantly and the leg would animate nothing.
        layoutIfNeeded()
        keyboardTargetHeight = max(0, targetHeight)
        surfaceView.beginHostedKeyboardTransition(isVisible: targetIsVisible)

        let endpoints = TerminalKeyboardDockEndpoints(
            boundsMaxY: bounds.maxY,
            bottomReservation: surfaceView.hostedBottomReservation(
                keyboardHeight: keyboardTargetHeight,
                bottomSafeAreaInset: resolvedBottomSafeAreaInset
            ),
            settledRenderBottom: surfaceView.hostedSettledRenderBottom(
                keyboardHeight: keyboardTargetHeight
            ),
            modelRenderBottom: surfaceView.hostedTerminalRenderBottom
        )
        dockBottomConstraint.constant = endpoints.dockBottomConstant
        presentationBottomConstraint.constant = endpoints.presentationBottomConstant
        keyboardTargetTop = endpoints.keyboardTopTarget
        keyboardTargetRenderBottom = endpoints.settledRenderBottom
        #if DEBUG
        maximumTerminalDockPresentationGap = 0
        maximumRendererDockPresentationGap = 0
        #endif

        transition.animate(durationOverride: durationOverride) { [weak self] in
            self?.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.keyboardTransitionGeneration == generation else { return }
            self.finishKeyboardTransition()
        }
    }

    /// Folds the settled geometry into the models without a visible change:
    /// the wrapper offset returns to zero in the same transaction that pins
    /// the renderer model at the settled edge the wrapper just animated to.
    private func finishKeyboardTransition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            surfaceView.finishHostedKeyboardTransition(
                keyboardHeight: keyboardTargetHeight,
                renderBottom: keyboardTargetRenderBottom
            )
            presentationBottomConstraint.constant = 0
            layoutIfNeeded()
        }
        CATransaction.commit()
        keyboardTransitionActive = false
        sampleTerminalDockPresentationGap()
    }

    private func settleDockWithoutKeyboardAnimation() {
        let reservation = surfaceView.hostedBottomReservation(
            keyboardHeight: keyboardTargetHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
        )
        dockBottomConstraint.constant = -reservation
        // Settled-state sync is path-independent: it folds the surface's
        // keyboard height/visibility to the recovered values and clears any
        // transition flag a detach interrupted, so a workspace switch cannot
        // strand the renderer mid-transition on either path.
        surfaceView.settleHostedKeyboard(
            height: keyboardTargetHeight,
            isVisible: keyboardFrameTracker.currentVisibility(in: self)
        )
        UIView.performWithoutAnimation {
            layoutIfNeeded()
        }
        keyboardTargetTop = surfaceView.hostedBottomDockFrame.maxY
        keyboardTargetRenderBottom = usesLegacyKeyboardDockPath
            ? surfaceView.hostedBottomDockFrame.minY
            : surfaceView.hostedTerminalRenderBottom
    }

    // MARK: - Legacy (iOS 27) keyboard path

    /// The pre-rebuild transition leg: the dock moves by constraint while the
    /// terminal wrapper moves by a transform in the same transaction, and the
    /// settled fold pins the renderer to the dock's top edge unconditionally.
    /// Kept byte-for-byte in behavior with the implementation that shipped
    /// before the single-constraint rebuild, because iOS 27 behaved correctly
    /// on it and misbehaves under the rebuilt path.
    private func beginLegacyKeyboardTransition(
        targetHeight: CGFloat,
        targetIsVisible: Bool,
        transition: MobileKeyboardTransition
    ) {
        // A fresh keyboard notification starts from the model tree. The live
        // presentation layers are meaningful only when this host is already
        // animating a prior keyboard leg.
        if keyboardTransitionActive {
            rebaseLegacyKeyboardPresentationFromLiveFrames()
        }
        layoutIfNeeded()
        keyboardTransitionGeneration &+= 1
        let generation = keyboardTransitionGeneration
        keyboardTransitionActive = true
        keyboardTargetHeight = max(0, targetHeight)
        surfaceView.beginHostedKeyboardTransition(isVisible: targetIsVisible)

        let reservation = surfaceView.hostedBottomReservation(
            keyboardHeight: keyboardTargetHeight,
            bottomSafeAreaInset: resolvedBottomSafeAreaInset
        )
        dockBottomConstraint.constant = -reservation
        keyboardTargetTop = max(0, bounds.maxY - reservation)
        let terminalBottom = max(0, keyboardTargetTop - surfaceView.hostedBottomDockHeight)
        keyboardTargetRenderBottom = terminalBottom
        let targetTranslation = terminalBottom - surfaceView.hostedTerminalRenderBottom
        #if DEBUG
        maximumTerminalDockPresentationGap = 0
        maximumRendererDockPresentationGap = 0
        #endif

        transition.animate { [weak self] in
            guard let self else { return }
            self.terminalPresentationView.transform = CGAffineTransform(
                translationX: 0,
                y: targetTranslation
            )
            self.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.keyboardTransitionGeneration == generation else { return }
            self.finishLegacyKeyboardTransition()
        }
    }

    private func finishLegacyKeyboardTransition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            surfaceView.finishHostedKeyboardTransition(
                keyboardHeight: keyboardTargetHeight,
                renderBottom: keyboardTargetRenderBottom
            )
            terminalPresentationView.transform = .identity
            layoutIfNeeded()
        }
        CATransaction.commit()
        keyboardTransitionActive = false
        sampleTerminalDockPresentationGap()
    }

    /// Rebase both sides of the terminal/dock boundary before a new keyboard
    /// leg. A reversal arrives while the previous leg still has separate Core
    /// Animation presentation trees for the dock constraint, clip boundary,
    /// and terminal wrapper; folding the live dock bottom into the constraint
    /// and the wrapper's live transform into its model lets the next
    /// `.beginFromCurrentState` transaction start every component at one edge.
    private func rebaseLegacyKeyboardPresentationFromLiveFrames() {
        let wrapperTransform: CGAffineTransform? = {
            guard let presentation = terminalPresentationView.layer.presentation(),
                  CATransform3DIsAffine(presentation.transform) else { return nil }
            return CATransform3DGetAffineTransform(presentation.transform)
        }()
        let liveDockBottom = surfaceView.hostedBottomDockPresentationBottom(in: self)

        guard wrapperTransform != nil || liveDockBottom != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            if let liveDockBottom {
                dockBottomConstraint.constant = liveDockBottom - bounds.maxY
            }
            if let wrapperTransform {
                terminalPresentationView.transform = wrapperTransform
            }
            // The clip bottom is constrained to the dock top. Layout before
            // removing the old animations so its model edge is the same live
            // edge as the dock.
            layoutIfNeeded()
            terminalClipView.layer.removeAllAnimations()
            surfaceView.removeHostedKeyboardMotionAnimations()
            terminalPresentationView.layer.removeAllAnimations()
        }
        CATransaction.commit()
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
        maximumRendererDockPresentationGap = max(
            maximumRendererDockPresentationGap,
            rendererDockPresentationGap
        )
        #endif
    }

    #if DEBUG
    var debugKeyboardTransitionID: Int { keyboardTransitionActive ? 1 : -1 }
    var debugUsesLegacyKeyboardDock: Bool { usesLegacyKeyboardDockPath }
    var debugKeyboardTargetHeight: CGFloat { keyboardTargetHeight }
    var debugKeyboardTargetTop: CGFloat { keyboardTargetTop }
    var debugTerminalDockPresentationGap: CGFloat {
        terminalDockPresentationGap
    }
    var debugMaximumTerminalDockPresentationGap: CGFloat {
        maximumTerminalDockPresentationGap
    }
    var debugRendererDockPresentationGap: CGFloat {
        rendererDockPresentationGap
    }
    var debugMaximumRendererDockPresentationGap: CGFloat {
        maximumRendererDockPresentationGap
    }

    /// The pixel seam between the terminal boundary and the bars: the clip
    /// view's live bottom edge vs the dock's live top edge. Both derive from
    /// one constraint in one animated layout pass, so this must hold near zero
    /// on EVERY frame of every transition — this is the per-frame contract the
    /// XCUITests assert.
    private var terminalDockPresentationGap: CGFloat {
        guard let dockTop = surfaceView.hostedBottomDockPresentationTop(in: self) else { return 0 }
        let clipLayer = terminalClipView.layer.presentation() ?? terminalClipView.layer
        let hostLayer = layer.presentation() ?? layer
        let clipBottom = clipLayer.convert(
            CGPoint(x: clipLayer.bounds.midX, y: clipLayer.bounds.maxY),
            to: hostLayer
        ).y
        return abs(clipBottom - dockTop)
    }

    /// How far the rendered content's bottom edge sits from the dock top.
    /// Nonzero mid-transition is INTENTIONAL when blank rows absorb the
    /// keyboard intrusion (the area in between shows terminal background);
    /// informational only, never a seam assertion.
    private var rendererDockPresentationGap: CGFloat {
        guard let terminalBottom = surfaceView.hostedTerminalPresentationBottom(in: self),
              let dockTop = surfaceView.hostedBottomDockPresentationTop(in: self) else { return 0 }
        return abs(terminalBottom - dockTop)
    }
    #endif
}
#endif
