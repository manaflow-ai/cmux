#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

@MainActor
final class ChatKeyboardTrackingViewController<Transcript: View, Composer: View>: UIViewController, UIGestureRecognizerDelegate {
    var transcriptView: Transcript {
        get { transcriptHostingController.rootView }
        set { transcriptHostingController.rootView = newValue }
    }

    var composerView: Composer {
        get { composerHostingController.rootView }
        set { composerHostingController.rootView = newValue }
    }

    var showsComposer: Bool {
        didSet { updateComposerVisibility() }
    }

    var excludedKeyboardDismissFrame: CGRect = .zero

    private let keyboardContentView = UIView(frame: .zero)
    let transcriptClipView = UIView(frame: .zero)
    private let composerBackgroundView = UIVisualEffectView(effect: nil)
    let transcriptHostingController: UIHostingController<Transcript>
    let composerHostingController: UIHostingController<Composer>
    weak var transcriptOverlayGeometry: ChatTranscriptOverlayGeometry?
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

    init(transcriptView: Transcript, composerView: Composer, showsComposer: Bool) {
        transcriptHostingController = UIHostingController(rootView: transcriptView)
        composerHostingController = UIHostingController(rootView: composerView)
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

        addChild(transcriptHostingController)
        transcriptHostingController.view.backgroundColor = .clear
        transcriptHostingController.safeAreaRegions = .container
        transcriptHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        transcriptClipView.addSubview(transcriptHostingController.view)

        composerBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        composerBackgroundView.isUserInteractionEnabled = false
        composerBackgroundView.clipsToBounds = true
        configureComposerBackground()
        keyboardContentView.addSubview(composerBackgroundView)

        addChild(composerHostingController)
        composerHostingController.view.backgroundColor = .clear
        composerHostingController.safeAreaRegions = .container
        composerHostingController.sizingOptions = [.intrinsicContentSize]
        composerHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        composerHostingController.view.setContentHuggingPriority(.required, for: .vertical)
        composerHostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        keyboardContentView.addSubview(composerHostingController.view)
        installLayoutConstraints()

        transcriptHostingController.didMove(toParent: self)
        composerHostingController.didMove(toParent: self)
        updateComposerVisibility()

        let observer = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
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
        let composerHeightConstraint = composerHostingController.view.heightAnchor.constraint(equalToConstant: 0)
        let transcriptClipTopConstraint = transcriptClipView.topAnchor.constraint(equalTo: keyboardContentView.topAnchor)
        let transcriptClipBottomConstraint = transcriptClipView.bottomAnchor.constraint(equalTo: composerHostingController.view.topAnchor)
        let transcriptHeightConstraint = transcriptHostingController.view.heightAnchor.constraint(equalToConstant: 0)
        let composerBottomConstraint = composerHostingController.view.bottomAnchor.constraint(equalTo: keyboardContentView.bottomAnchor)
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

            transcriptHostingController.view.leadingAnchor.constraint(equalTo: transcriptClipView.leadingAnchor),
            transcriptHostingController.view.trailingAnchor.constraint(equalTo: transcriptClipView.trailingAnchor),
            transcriptHostingController.view.topAnchor.constraint(equalTo: transcriptClipView.topAnchor),
            transcriptHeightConstraint,

            composerBackgroundView.topAnchor.constraint(equalTo: composerHostingController.view.topAnchor),
            composerBackgroundView.leadingAnchor.constraint(equalTo: keyboardContentView.leadingAnchor),
            composerBackgroundView.trailingAnchor.constraint(equalTo: keyboardContentView.trailingAnchor),
            composerBackgroundView.bottomAnchor.constraint(equalTo: keyboardContentView.bottomAnchor),

            composerHostingController.view.leadingAnchor.constraint(equalTo: keyboardContentView.leadingAnchor),
            composerHostingController.view.trailingAnchor.constraint(equalTo: keyboardContentView.trailingAnchor),
            composerBottomConstraint,
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
            stopKeyboardAnimation(removeAnimations: true)
            applyKeyboardOverlap(targetOverlap)
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
        transcriptHostingController.view.layer.removeAllAnimations()
        composerBackgroundView.layer.removeAllAnimations()
        composerHostingController.view.layer.removeAllAnimations()
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
        let fullTranscriptHeight = max(0, layoutHeight)
        updateConstraint(composerHeightConstraint, to: composerHeight)
        updateConstraint(transcriptClipTopConstraint, to: 0)
        updateConstraint(transcriptClipBottomConstraint, to: 0)
        updateConstraint(transcriptHeightConstraint, to: fullTranscriptHeight)
        if let transcriptOverlayGeometry,
           abs(transcriptOverlayGeometry.composerBottomInset - overlayBottomInset) > 0.5 {
            transcriptOverlayGeometry.composerBottomInset = overlayBottomInset
        }
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
        if let composerFrame = presentationFrameInOwnViewCoordinates(for: composerHostingController.view) {
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
        let measured = composerHostingController.sizeThatFits(in: fittingSize)
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
        let tables = trackedTranscriptTables(in: transcriptHostingController.view)
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
            composerView: composerHostingController.view
        )
    }

    private func updateComposerVisibility() {
        guard isViewLoaded else { return }
        composerHostingController.view.isHidden = !showsComposer
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
            // Stop at the transcript table itself; descending into its own
            // cells/hosted row views would re-walk the entire transcript on
            // every layout/keyboard geometry update.
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
        let transcriptFrame = transcriptHostingController.view.convert(
            transcriptHostingController.view.bounds,
            to: window
        )
        guard transcriptFrame.contains(point) else { return false }
        guard !excludedKeyboardDismissFrame.contains(point) else { return false }
        let composerFrame = composerHostingController.view.convert(
            composerHostingController.view.bounds,
            to: window
        )
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
