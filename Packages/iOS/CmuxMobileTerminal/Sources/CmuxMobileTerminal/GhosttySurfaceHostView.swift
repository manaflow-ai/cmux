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
/// The terminal presentation and dock animate in one transaction. The Metal surface
/// remains full-size and unchanged behind ``terminalClipView`` until the transition
/// settles, so keyboard motion cannot race a display-link geometry correction.
@MainActor
public final class GhosttySurfaceHostView: UIView {
    public let surfaceView: GhosttySurfaceView
    private let terminalClipView = UIView()
    private let terminalPresentationView = UIView()
    private var dockBottomConstraint: NSLayoutConstraint!
    private let keyboardDockGeometrySource = KeyboardDockGeometrySource.current
    private var keyboardTransitionGeneration: UInt64 = 0
    private var keyboardTransitionActive = false
    private var keyboardTargetHeight: CGFloat = 0
    private var keyboardTargetTop: CGFloat = 0
    private var keyboardTargetTerminalBottom: CGFloat = 0
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
            dockBottomConstraint.isActive = false
            keyboardLayoutGuide.followsUndockedKeyboard = true
            keyboardLayoutGuide.usesBottomSafeArea = true
            dockBottomConstraint = surfaceView.hostedBottomDockBottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor
            )
            dockBottomConstraint.isActive = true
        }

        NSLayoutConstraint.activate([
            terminalClipView.topAnchor.constraint(equalTo: topAnchor),
            terminalClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalClipView.bottomAnchor.constraint(equalTo: surfaceView.hostedBottomDockTopAnchor),

            terminalPresentationView.topAnchor.constraint(equalTo: topAnchor),
            terminalPresentationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalPresentationView.widthAnchor.constraint(equalTo: widthAnchor),
            terminalPresentationView.heightAnchor.constraint(equalTo: heightAnchor),

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
            terminalPresentationView.layer.removeAllAnimations()
            terminalPresentationView.transform = .identity
            return
        }
        guard !keyboardTransitionActive else { return }
        settleDockWithoutKeyboardAnimation()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard keyboardDockGeometrySource == .systemLayoutGuide,
              !keyboardTransitionActive else { return }
        surfaceView.updateHostedKeyboardLayoutGuide(
            height: keyboardLayoutGuideOverlap
        )
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        guard !keyboardTransitionActive else { return }
        settleDockWithoutKeyboardAnimation()
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard window != nil,
              let transition = MobileKeyboardTransition(notification: notification) else { return }
        let targetHeight = transition.overlap(in: self)
        let targetIsVisible = transition.isVisible(in: self)
        beginKeyboardTransition(
            targetHeight: targetHeight,
            targetIsVisible: targetIsVisible,
            transition: transition
        )
    }

    private func beginKeyboardTransition(
        targetHeight: CGFloat,
        targetIsVisible: Bool,
        transition: MobileKeyboardTransition
    ) {
        // A fresh keyboard notification starts from the model tree. The live
        // presentation layers are meaningful only when this host is already
        // animating a prior keyboard leg. Rebasing on every notification can
        // fold an unrelated settled presentation transform into the first leg,
        // making the terminal begin several points away from its dock.
        if keyboardTransitionActive {
            rebaseKeyboardPresentationFromLiveFrames()
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
        if keyboardDockGeometrySource == .keyboardNotifications {
            dockBottomConstraint.constant = -reservation
        }
        keyboardTargetTop = max(0, bounds.maxY - reservation)
        keyboardTargetTerminalBottom = max(
            0,
            keyboardTargetTop - surfaceView.hostedBottomDockHeight
        )
        let rendererBottom = surfaceView.hostedTerminalRenderBottom
        let targetTranslation = keyboardTargetTerminalBottom - rendererBottom
        #if DEBUG
        maximumTerminalDockPresentationGap = 0
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
            self.finishKeyboardTransition()
        }
    }

    private func finishKeyboardTransition() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            surfaceView.finishHostedKeyboardTransition(
                keyboardHeight: keyboardTargetHeight,
                terminalBottom: keyboardTargetTerminalBottom
            )
            terminalPresentationView.transform = .identity
            layoutIfNeeded()
        }
        CATransaction.commit()
        keyboardTransitionActive = false
        sampleTerminalDockPresentationGap()
    }

    private func settleDockWithoutKeyboardAnimation() {
        if keyboardDockGeometrySource == .keyboardNotifications {
            let reservation = surfaceView.hostedBottomReservation(
                keyboardHeight: keyboardTargetHeight,
                bottomSafeAreaInset: resolvedBottomSafeAreaInset
            )
            dockBottomConstraint.constant = -reservation
        }
        UIView.performWithoutAnimation {
            layoutIfNeeded()
        }
        keyboardTargetTop = surfaceView.hostedBottomDockFrame.maxY
        keyboardTargetTerminalBottom = surfaceView.hostedBottomDockFrame.minY
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

    /// Rebase both sides of the terminal/dock boundary before a new keyboard will.
    ///
    /// A reversal arrives while the previous leg still has separate Core Animation
    /// presentation trees for the dock constraint, clip boundary, and terminal
    /// wrapper. Rebasing only the wrapper makes its next `.beginFromCurrentState`
    /// animation start at the live edge while the clip remains at the old target,
    /// exposing a one-frame gap. The notification fallback owns the dock constraint,
    /// so it can first fold the live dock bottom into that constraint, lay out the
    /// linked clip without actions, then fold the wrapper's live transform into its
    /// model. The next transaction therefore starts every owned component at one edge.
    private func rebaseKeyboardPresentationFromLiveFrames() {
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
            if keyboardDockGeometrySource == .keyboardNotifications,
               let liveDockBottom {
                dockBottomConstraint.constant = liveDockBottom - bounds.maxY
            }
            if let wrapperTransform {
                terminalPresentationView.transform = wrapperTransform
            }
            // The clip bottom is constrained to the dock top. Layout before removing
            // the old animations so its model edge is the same live edge as the dock.
            layoutIfNeeded()
            terminalClipView.layer.removeAllAnimations()
            surfaceView.removeHostedBottomDockAnimations()
            terminalPresentationView.layer.removeAllAnimations()
        }
        CATransaction.commit()
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
    var debugUsesNotificationKeyboardDock: Bool {
        keyboardDockGeometrySource == .keyboardNotifications
    }
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
