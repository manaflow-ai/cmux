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
    #endif

    public init(
        surfaceView: GhosttySurfaceView,
        keyboardFrameTracker: MobileKeyboardFrameTracker = .shared
    ) {
        self.surfaceView = surfaceView
        self.keyboardFrameTracker = keyboardFrameTracker
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
            terminalPresentationView.layer.removeAllAnimations()
            terminalClipView.layer.removeAllAnimations()
            surfaceView.removeHostedKeyboardMotionAnimations()
            return
        }
        guard !keyboardTransitionActive else { return }
        // Recover any keyboard transition that happened while detached: the
        // tracker records keyboard frames process-wide, so a workspace switch
        // that detached this host mid-transition cannot wedge the dock at its
        // stale pre-detach seat.
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

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard window != nil,
              let transition = MobileKeyboardTransition(notification: notification) else { return }
        beginKeyboardTransition(
            targetHeight: transition.overlap(in: self),
            targetIsVisible: transition.isVisible(in: self),
            transition: transition
        )
    }

    private func beginKeyboardTransition(
        targetHeight: CGFloat,
        targetIsVisible: Bool,
        transition: MobileKeyboardTransition
    ) {
        // Flush layout that predates this keyboard leg so the animated pass
        // below carries only keyboard motion.
        layoutIfNeeded()
        keyboardTransitionGeneration &+= 1
        let generation = keyboardTransitionGeneration
        keyboardTransitionActive = true
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
        #endif

        transition.animate { [weak self] in
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
        surfaceView.settleHostedKeyboard(
            height: keyboardTargetHeight,
            isVisible: keyboardFrameTracker.currentVisibility(in: self)
        )
        UIView.performWithoutAnimation {
            layoutIfNeeded()
        }
        keyboardTargetTop = surfaceView.hostedBottomDockFrame.maxY
        keyboardTargetRenderBottom = surfaceView.hostedTerminalRenderBottom
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
    var debugKeyboardTransitionID: Int { keyboardTransitionActive ? 1 : -1 }
    var debugKeyboardTargetHeight: CGFloat { keyboardTargetHeight }
    var debugKeyboardTargetTop: CGFloat { keyboardTargetTop }
    var debugTerminalDockPresentationGap: CGFloat {
        terminalDockPresentationGap
    }
    var debugMaximumTerminalDockPresentationGap: CGFloat {
        maximumTerminalDockPresentationGap
    }

    private var terminalDockPresentationGap: CGFloat {
        guard let terminalBottom = surfaceView.hostedTerminalPresentationBottom(in: self),
              let dockTop = surfaceView.hostedBottomDockPresentationTop(in: self) else { return 0 }
        return abs(terminalBottom - dockTop)
    }
    #endif
}
#endif
