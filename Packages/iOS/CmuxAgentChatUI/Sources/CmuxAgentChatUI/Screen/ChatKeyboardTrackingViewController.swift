#if os(iOS)
import CmuxMobileSupport
import UIKit

@MainActor
final class ChatKeyboardTrackingViewController: UIViewController, UIGestureRecognizerDelegate {
    let transcriptView: UIView
    let composerView: UIView

    var showsComposer: Bool {
        didSet { updateComposerVisibility() }
    }

    var excludedKeyboardDismissFrame: CGRect = .zero

    private let keyboardContentView = UIView(frame: .zero)
    private let transcriptClipView = UIView(frame: .zero)
    private let bottomChromeContainerView = UIView(frame: .zero)
    private let composerBackgroundView = UIVisualEffectView(effect: nil)
    private var composerHeightConstraint: NSLayoutConstraint?
    private var transcriptClipTopConstraint: NSLayoutConstraint?
    private var transcriptClipBottomConstraint: NSLayoutConstraint?
    private var transcriptHeightConstraint: NSLayoutConstraint?
    private var composerBottomConstraint: NSLayoutConstraint?
    private let scrollEdgeCoordinator = ChatScrollEdgeCoordinator()

    var keyboardOverlap: CGFloat = 0
    var keyboardTransitionID = 0
    private var lastKeyboardTransitionDuration: TimeInterval = 0.3833
    var isKeyboardAnimationActive = false
    var keyboardAnimationStartOverlap: CGFloat = 0
    var keyboardAnimationTargetOverlap: CGFloat = 0
    #if DEBUG
    var keyboardDebugEventCount = 0
    var keyboardDebugTransitionDuration: TimeInterval = 0
    #endif
    private var keyboardObservers: [ChatKeyboardNotificationToken] = []
    private weak var installedWindow: UIWindow?

    private lazy var dismissTapRecognizer: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDismissTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    init(transcriptView: UIView, composerView: UIView, showsComposer: Bool) {
        self.transcriptView = transcriptView
        self.composerView = composerView
        self.showsComposer = showsComposer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used in storyboards") }

    deinit {
        for observer in keyboardObservers {
            observer.remove()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

        keyboardContentView.backgroundColor = .clear
        keyboardContentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardContentView)

        transcriptClipView.backgroundColor = .clear
        transcriptClipView.clipsToBounds = true
        transcriptClipView.translatesAutoresizingMaskIntoConstraints = false
        keyboardContentView.addSubview(transcriptClipView)

        transcriptView.backgroundColor = .clear
        transcriptView.translatesAutoresizingMaskIntoConstraints = false
        transcriptClipView.addSubview(transcriptView)

        bottomChromeContainerView.backgroundColor = .clear
        bottomChromeContainerView.clipsToBounds = false
        bottomChromeContainerView.translatesAutoresizingMaskIntoConstraints = false
        keyboardContentView.addSubview(bottomChromeContainerView)

        composerBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        composerBackgroundView.isUserInteractionEnabled = false
        composerBackgroundView.clipsToBounds = true
        configureComposerBackground()
        bottomChromeContainerView.addSubview(composerBackgroundView)

        composerView.backgroundColor = .clear
        composerView.translatesAutoresizingMaskIntoConstraints = false
        composerView.setContentHuggingPriority(.required, for: .vertical)
        composerView.setContentCompressionResistancePriority(.required, for: .vertical)
        bottomChromeContainerView.addSubview(composerView)
        installLayoutConstraints()

        updateComposerVisibility()

        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            guard let transition = MobileKeyboardTransition(notification: notification) else {
                return
            }
            MainActor.assumeIsolated {
                self?.keyboardWillChangeFrame(transition)
            }
        }
        keyboardObservers.append(ChatKeyboardNotificationToken(observer))
    }

    private func installLayoutConstraints() {
        let composerHeightConstraint = composerView.heightAnchor.constraint(equalToConstant: 0)
        let transcriptClipTopConstraint = transcriptClipView.topAnchor.constraint(equalTo: keyboardContentView.topAnchor)
        let transcriptClipBottomConstraint = transcriptClipView.bottomAnchor.constraint(equalTo: keyboardContentView.bottomAnchor)
        let transcriptHeightConstraint = transcriptView.heightAnchor.constraint(equalToConstant: 0)
        let composerBottomConstraint = bottomChromeContainerView.bottomAnchor.constraint(equalTo: keyboardContentView.bottomAnchor)
        self.composerHeightConstraint = composerHeightConstraint
        self.transcriptClipTopConstraint = transcriptClipTopConstraint
        self.transcriptClipBottomConstraint = transcriptClipBottomConstraint
        self.transcriptHeightConstraint = transcriptHeightConstraint
        self.composerBottomConstraint = composerBottomConstraint

        NSLayoutConstraint.activate([
            keyboardContentView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardContentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardContentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardContentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            transcriptClipTopConstraint,
            transcriptClipView.leadingAnchor.constraint(equalTo: keyboardContentView.leadingAnchor),
            transcriptClipView.trailingAnchor.constraint(equalTo: keyboardContentView.trailingAnchor),
            transcriptClipBottomConstraint,

            transcriptView.leadingAnchor.constraint(equalTo: transcriptClipView.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: transcriptClipView.trailingAnchor),
            transcriptView.topAnchor.constraint(equalTo: transcriptClipView.topAnchor),
            transcriptHeightConstraint,

            bottomChromeContainerView.topAnchor.constraint(equalTo: composerView.topAnchor),
            bottomChromeContainerView.leadingAnchor.constraint(equalTo: keyboardContentView.leadingAnchor),
            bottomChromeContainerView.trailingAnchor.constraint(equalTo: keyboardContentView.trailingAnchor),
            composerBottomConstraint,

            composerBackgroundView.topAnchor.constraint(equalTo: bottomChromeContainerView.topAnchor),
            composerBackgroundView.leadingAnchor.constraint(equalTo: bottomChromeContainerView.leadingAnchor),
            composerBackgroundView.trailingAnchor.constraint(equalTo: bottomChromeContainerView.trailingAnchor),
            composerBackgroundView.bottomAnchor.constraint(equalTo: bottomChromeContainerView.bottomAnchor),

            composerView.leadingAnchor.constraint(equalTo: bottomChromeContainerView.leadingAnchor),
            composerView.trailingAnchor.constraint(equalTo: bottomChromeContainerView.trailingAnchor),
            composerView.bottomAnchor.constraint(equalTo: bottomChromeContainerView.bottomAnchor),
            composerHeightConstraint,
        ])
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateMeasuredGeometryConstants()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installDismissTapIfNeeded()
        updateMeasuredGeometryConstants()
        #if DEBUG
        updateKeyboardDebugValues(overlap: keyboardOverlap)
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopKeyboardAnimation(removeAnimations: true)
        installedWindow?.removeGestureRecognizer(dismissTapRecognizer)
        installedWindow = nil
        scrollEdgeCoordinator.reset()
    }

    private func installDismissTapIfNeeded() {
        if view.window !== installedWindow {
            installedWindow?.removeGestureRecognizer(dismissTapRecognizer)
            installedWindow = nil
        }
        guard installedWindow == nil, let window = view.window else { return }
        window.addGestureRecognizer(dismissTapRecognizer)
        installedWindow = window
    }

    private func keyboardWillChangeFrame(_ transition: MobileKeyboardTransition) {
        let overlap = transition.overlap(in: view)
        let visibleOverlap = currentVisibleKeyboardOverlap()
        if abs(visibleOverlap - overlap) <= 0.5, !isKeyboardAnimationActive {
            return
        }
        if isKeyboardAnimationActive, abs(overlap - keyboardAnimationTargetOverlap) <= 0.5 {
            #if DEBUG
            updateKeyboardDebugValues(overlap: keyboardOverlap)
            #endif
            return
        }
        let effectiveDuration = effectiveKeyboardTransitionDuration(
            for: transition,
            startOverlap: visibleOverlap,
            targetOverlap: overlap
        )
        #if DEBUG
        keyboardDebugTransitionDuration = effectiveDuration
        keyboardDebugEventCount += 1
        updateKeyboardDebugValues(overlap: overlap)
        #endif
        keyboardTransitionID &+= 1
        let transitionID = keyboardTransitionID
        startKeyboardTracking(
            from: visibleOverlap,
            to: overlap,
            transition: transition,
            duration: effectiveDuration,
            transitionID: transitionID
        )
    }

    private func effectiveKeyboardTransitionDuration(
        for transition: MobileKeyboardTransition,
        startOverlap: CGFloat,
        targetOverlap: CGFloat
    ) -> TimeInterval {
        if transition.duration > 0 {
            lastKeyboardTransitionDuration = transition.duration
            return transition.duration
        }
        let remainingDistance = abs(targetOverlap - startOverlap)
        guard remainingDistance > 0.5 else { return 0 }
        if isKeyboardAnimationActive {
            let referenceDistance = max(
                abs(keyboardAnimationTargetOverlap - keyboardAnimationStartOverlap),
                keyboardAnimationTargetOverlap,
                keyboardAnimationStartOverlap,
                keyboardOverlap,
                targetOverlap
            )
            if referenceDistance > 0.5 {
                let remainingFraction = min(max(remainingDistance / referenceDistance, 0.15), 1)
                return max(1.0 / 60.0, lastKeyboardTransitionDuration * remainingFraction)
            }
        }
        if abs(targetOverlap - keyboardOverlap) > 0.5 {
            return lastKeyboardTransitionDuration
        }
        return 0
    }

    private func startKeyboardTracking(
        from startOverlap: CGFloat,
        to targetOverlap: CGFloat,
        transition: MobileKeyboardTransition,
        duration: TimeInterval,
        transitionID: Int
    ) {
        guard duration > 0, abs(targetOverlap - startOverlap) > 0.5 else {
            stopKeyboardAnimation(removeAnimations: false)
            pinAnimationToVisibleOverlap(targetOverlap)
            return
        }

        pinAnimationToVisibleOverlap(startOverlap)
        isKeyboardAnimationActive = true
        keyboardAnimationStartOverlap = startOverlap
        keyboardAnimationTargetOverlap = targetOverlap
        view.layoutIfNeeded()

        transition.animate(durationOverride: duration) {
            self.applyKeyboardOverlap(targetOverlap)
            self.updateMeasuredGeometryConstants()
            self.view.layoutIfNeeded()
        } completion: { _ in
            guard self.keyboardTransitionID == transitionID else { return }
            self.finishKeyboardAnimation()
        }
    }

    private func finishKeyboardAnimation() {
        isKeyboardAnimationActive = false
        applyKeyboardOverlap(keyboardAnimationTargetOverlap)
        updateMeasuredGeometryConstants()
        #if DEBUG
        updateKeyboardDebugValues(overlap: keyboardOverlap)
        #endif
    }

    private func stopKeyboardAnimation(removeAnimations: Bool) {
        isKeyboardAnimationActive = false
        if removeAnimations {
            removeKeyboardTrackingAnimations()
        }
    }

    private func removeKeyboardTrackingAnimations() {
        keyboardContentView.layer.removeAllAnimations()
        transcriptClipView.layer.removeAllAnimations()
        transcriptView.layer.removeAllAnimations()
        bottomChromeContainerView.layer.removeAllAnimations()
        composerBackgroundView.layer.removeAllAnimations()
        composerView.layer.removeAllAnimations()
    }

    private func updateMeasuredGeometryConstants() {
        let bounds = view.bounds
        let safeAreaUnderlap = bottomSafeAreaUnderlap
        let layoutHeight = bounds.height + safeAreaUnderlap
        let composerHeight = measuredComposerHeight(width: bounds.width)
        let overlayBottomInset = transcriptOverlayBottomInset(
            composerHeight: composerHeight,
            bottomSafeAreaUnderlap: safeAreaUnderlap
        )
        let adjustedBottomInset = overlayBottomInset + keyboardOverlap
        let clipBottomConstant = transcriptClipBottomConstant(bottomSafeAreaUnderlap: safeAreaUnderlap)
        let fullTranscriptHeight = max(0, layoutHeight)
        updateConstraint(composerHeightConstraint, to: composerHeight)
        updateConstraint(transcriptClipTopConstraint, to: 0)
        updateConstraint(transcriptClipBottomConstraint, to: clipBottomConstant)
        updateConstraint(transcriptHeightConstraint, to: fullTranscriptHeight)
        updateTranscriptViewportInsets(
            adjustedBottomInset: adjustedBottomInset,
            composerOverlayBottomInset: overlayBottomInset
        )
    }

    private func applyKeyboardOverlap(_ overlap: CGFloat) {
        let clampedOverlap = min(max(0, overlap), max(0, view.bounds.height))
        keyboardOverlap = clampedOverlap
        updateConstraint(composerBottomConstraint, to: -clampedOverlap)
    }

    private func pinAnimationToVisibleOverlap(_ overlap: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            applyKeyboardOverlap(overlap)
            updateMeasuredGeometryConstants()
            view.layoutIfNeeded()
            removeKeyboardTrackingAnimations()
        }
        CATransaction.commit()
    }

    func currentVisibleKeyboardOverlap() -> CGFloat {
        if let composerFrame = presentationFrameInOwnViewCoordinates(for: composerView) {
            return min(max(0, view.bounds.maxY - composerFrame.maxY), max(0, view.bounds.height))
        }
        return keyboardOverlap
    }

    private func presentationFrameInOwnViewCoordinates(for targetView: UIView) -> CGRect? {
        let sourceLayer = targetView.layer.presentation() ?? targetView.layer
        let targetLayer = view.layer.presentation() ?? view.layer
        return sourceLayer.convert(targetView.bounds, to: targetLayer)
    }

    private var bottomSafeAreaUnderlap: CGFloat {
        max(0, view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom)
    }

    private func transcriptOverlayBottomInset(
        composerHeight: CGFloat,
        bottomSafeAreaUnderlap: CGFloat
    ) -> CGFloat {
        let visibleComposerHeight = showsComposer ? composerHeight : 0
        return max(0, ceil(visibleComposerHeight + bottomSafeAreaUnderlap))
    }

    private func transcriptClipBottomConstant(bottomSafeAreaUnderlap: CGFloat) -> CGFloat {
        guard keyboardOverlap > 0.5 else {
            return max(0, ceil(bottomSafeAreaUnderlap))
        }
        // The composer follows the full keyboard reservation. The transcript
        // clip stops at the visual keyboard chrome so bottom chrome can overlay
        // live rows without letting rows enter the key plane.
        let visualKeyboardChromeOverlap = max(0, keyboardOverlap - bottomSafeAreaUnderlap)
        return -ceil(visualKeyboardChromeOverlap)
    }

    private func updateConstraint(_ constraint: NSLayoutConstraint?, to constant: CGFloat) {
        guard let constraint, abs(constraint.constant - constant) > 0.5 else { return }
        constraint.constant = constant
    }

    private func measuredComposerHeight(width: CGFloat) -> CGFloat {
        guard showsComposer, width > 0 else { return 0 }
        let fittingSize = CGSize(
            width: width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let measured = composerView.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return max(0, ceil(measured.height))
    }

    private func configureComposerBackground() {
        if #available(iOS 26.0, *) {
            composerBackgroundView.effect = nil
            composerBackgroundView.backgroundColor = .clear
        } else {
            composerBackgroundView.effect = UIBlurEffect(style: .systemThinMaterial)
            composerBackgroundView.backgroundColor = .clear
        }
    }

    private func updateTranscriptViewportInsets(
        adjustedBottomInset: CGFloat,
        composerOverlayBottomInset: CGFloat
    ) {
        (transcriptView as? ChatTranscriptNativeView)?.setComposerOverlayBottomInset(
            composerOverlayBottomInset
        )
        let tables = trackedTranscriptTables(in: transcriptView)
        for tableView in tables {
            tableView.applyTranscriptViewportInsets(
                topChromeInset: 0,
                adjustedBottomInset: adjustedBottomInset,
                composerOverlayBottomInset: composerOverlayBottomInset
            )
        }
        scrollEdgeCoordinator.configure(
            tableView: tables.first,
            owner: self,
            bottomChromeView: bottomChromeContainerView
        )
    }

    private func updateComposerVisibility() {
        guard isViewLoaded else { return }
        bottomChromeContainerView.isHidden = !showsComposer
        composerView.isHidden = !showsComposer
        composerBackgroundView.isHidden = !showsComposer
        updateMeasuredGeometryConstants()
        view.setNeedsLayout()
    }

    @objc private func handleDismissTap() {
        view.window?.endEditing(true)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    func trackedTranscriptTables(in view: UIView) -> [ChatTranscriptUITableView] {
        if let table = view as? ChatTranscriptUITableView {
            // Stop at the transcript table itself to avoid walking hosted rows.
            return [table]
        }
        var tables: [ChatTranscriptUITableView] = []
        for subview in view.subviews {
            tables.append(contentsOf: trackedTranscriptTables(in: subview))
        }
        return tables
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard let window = view.window else { return false }
        let point = touch.location(in: window)
        let transcriptFrame = transcriptView.convert(transcriptView.bounds, to: window)
        guard transcriptFrame.contains(point) else { return false }
        guard !excludedKeyboardDismissFrame.contains(point) else { return false }
        let composerFrame = composerView.convert(composerView.bounds, to: window)
        return !composerFrame.contains(point)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

#endif
