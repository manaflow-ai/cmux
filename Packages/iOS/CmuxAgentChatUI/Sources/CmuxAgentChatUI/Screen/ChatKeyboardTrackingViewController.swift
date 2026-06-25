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

    private let transcriptHostingController: UIHostingController<Transcript>
    private let composerHostingController: UIHostingController<Composer>
    private typealias ScrollSnapshot = (scrollView: ChatTranscriptUITableView, snapshot: MobileScrollViewportSnapshot)

    private let keyboardProgressView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var activeKeyboardScrollSnapshots: [ScrollSnapshot] = []
    private var isRestoringKeyboardViewport = false
    private var keyboardOverlap: CGFloat = 0
    private var keyboardTransitionID = 0
    private var lastKeyboardTransitionDuration: TimeInterval = 0.3833
    private var keyboardFrameAnimation: ChatKeyboardFrameAnimation?
    private var keyboardViewportDisplayLink: CADisplayLink?
    #if DEBUG
    private var keyboardDebugEventCount = 0
    private var keyboardDebugTransitionDuration: TimeInterval = 0
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
        view.clipsToBounds = true

        keyboardProgressView.alpha = 0
        keyboardProgressView.isUserInteractionEnabled = false
        keyboardProgressView.accessibilityElementsHidden = true
        keyboardProgressView.isAccessibilityElement = false
        keyboardProgressView.center = .zero
        view.addSubview(keyboardProgressView)

        addChild(transcriptHostingController)
        transcriptHostingController.view.backgroundColor = .clear
        transcriptHostingController.safeAreaRegions = .container
        transcriptHostingController.view.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(transcriptHostingController.view)

        addChild(composerHostingController)
        composerHostingController.view.backgroundColor = .clear
        composerHostingController.safeAreaRegions = .container
        composerHostingController.sizingOptions = [.intrinsicContentSize]
        composerHostingController.view.translatesAutoresizingMaskIntoConstraints = true
        composerHostingController.view.setContentHuggingPriority(.required, for: .vertical)
        composerHostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(composerHostingController.view)

        transcriptHostingController.didMove(toParent: self)
        composerHostingController.didMove(toParent: self)
        updateComposerVisibility()

        for name in [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let transition = MobileKeyboardTransition(notification: notification) else {
                    return
                }
                Task { @MainActor [weak self, transition] in
                    self?.keyboardWillChangeFrame(transition)
                }
            }
            keyboardObservers.append(ChatKeyboardNotificationToken(observer))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installDismissTapIfNeeded()
        layoutChatGeometry(overlap: keyboardOverlap, preserving: activeKeyboardScrollSnapshots)
        #if DEBUG
        updateKeyboardDebugValues(overlap: keyboardOverlap)
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopKeyboardFrameAnimation()
        activeKeyboardScrollSnapshots = []
        installedWindow?.removeGestureRecognizer(dismissTapRecognizer)
        installedWindow = nil
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
        if let keyboardFrameAnimation,
           abs(keyboardFrameAnimation.targetOverlap - overlap) <= 0.5 {
            return
        }
        let effectiveDuration = effectiveKeyboardTransitionDuration(for: transition, targetOverlap: overlap)
        #if DEBUG
        keyboardDebugTransitionDuration = effectiveDuration
        keyboardDebugEventCount += 1
        updateKeyboardDebugValues(overlap: overlap)
        #endif
        let scrollSnapshots = activeKeyboardScrollSnapshots.isEmpty
            ? trackedScrollSnapshots()
            : activeKeyboardScrollSnapshots
        activeKeyboardScrollSnapshots = scrollSnapshots
        keyboardTransitionID &+= 1
        let transitionID = keyboardTransitionID
        startKeyboardFrameAnimation(
            to: overlap,
            transition: transition,
            duration: effectiveDuration,
            preserving: scrollSnapshots,
            transitionID: transitionID
        )
    }

    private func effectiveKeyboardTransitionDuration(
        for transition: MobileKeyboardTransition,
        targetOverlap: CGFloat
    ) -> TimeInterval {
        if transition.duration > 0 {
            lastKeyboardTransitionDuration = transition.duration
            return transition.duration
        }
        if abs(targetOverlap - keyboardOverlap) > 0.5 {
            return lastKeyboardTransitionDuration
        }
        return 0
    }

    private func startKeyboardFrameAnimation(
        to targetOverlap: CGFloat,
        transition: MobileKeyboardTransition,
        duration: TimeInterval,
        preserving scrollSnapshots: [ScrollSnapshot],
        transitionID: Int
    ) {
        let startOverlap = keyboardOverlap
        stopKeyboardFrameAnimation()
        guard duration > 0, abs(targetOverlap - startOverlap) > 0.5 else {
            layoutChatGeometry(overlap: targetOverlap, preserving: scrollSnapshots)
            activeKeyboardScrollSnapshots = []
            return
        }

        setKeyboardViewportExternallyDriven(true, for: scrollSnapshots)
        keyboardFrameAnimation = ChatKeyboardFrameAnimation(
            id: transitionID,
            startOverlap: startOverlap,
            targetOverlap: targetOverlap,
            scrollSnapshots: scrollSnapshots
        )
        keyboardProgressView.layer.removeAllAnimations()
        keyboardProgressView.center = CGPoint(x: 0, y: 0)
        layoutChatGeometry(overlap: startOverlap, preserving: scrollSnapshots, disablesAnimations: true)
        startKeyboardViewportDisplayLink()

        transition.animate(durationOverride: duration) {
            self.keyboardProgressView.center = CGPoint(x: 1, y: 0)
        } completion: { _ in
            guard self.keyboardTransitionID == transitionID else { return }
            self.finishKeyboardFrameAnimation(targetOverlap: targetOverlap, preserving: scrollSnapshots)
        }
    }

    private func finishKeyboardFrameAnimation(
        targetOverlap: CGFloat,
        preserving scrollSnapshots: [ScrollSnapshot]
    ) {
        stopKeyboardFrameAnimation(clearDrivenTables: false)
        layoutChatGeometry(overlap: targetOverlap, preserving: scrollSnapshots)
        setKeyboardViewportExternallyDriven(false, for: scrollSnapshots)
        activeKeyboardScrollSnapshots = []
    }

    private func stopKeyboardFrameAnimation(clearDrivenTables: Bool = true) {
        if clearDrivenTables, let keyboardFrameAnimation {
            setKeyboardViewportExternallyDriven(false, for: keyboardFrameAnimation.scrollSnapshots)
        }
        keyboardViewportDisplayLink?.invalidate()
        keyboardViewportDisplayLink = nil
        keyboardFrameAnimation = nil
        keyboardProgressView.layer.removeAllAnimations()
    }

    private func startKeyboardViewportDisplayLink() {
        guard keyboardViewportDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(keyboardViewportDisplayLinkDidTick))
        displayLink.add(to: .main, forMode: .common)
        keyboardViewportDisplayLink = displayLink
    }

    @objc private func keyboardViewportDisplayLinkDidTick() {
        guard let animation = keyboardFrameAnimation else {
            keyboardViewportDisplayLink?.invalidate()
            keyboardViewportDisplayLink = nil
            return
        }
        let progress = currentKeyboardFrameAnimationProgress()
        let overlap = animation.startOverlap
            + ((animation.targetOverlap - animation.startOverlap) * progress)
        layoutChatGeometry(
            overlap: overlap,
            preserving: animation.scrollSnapshots,
            disablesAnimations: true
        )
        #if DEBUG
        updateKeyboardDebugValues(overlap: keyboardOverlap)
        #endif
    }

    private func currentKeyboardFrameAnimationProgress() -> CGFloat {
        let rawProgress = keyboardProgressView.layer.presentation()?.position.x
            ?? keyboardProgressView.layer.position.x
        return min(max(rawProgress, 0), 1)
    }

    private func layoutChatGeometry(
        overlap: CGFloat,
        preserving scrollSnapshots: [ScrollSnapshot] = [],
        disablesAnimations: Bool = false
    ) {
        let update = {
            self.updateChatGeometry(overlap: overlap, preserving: scrollSnapshots)
        }
        guard disablesAnimations else {
            update()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation(update)
        CATransaction.commit()
    }

    private func updateChatGeometry(
        overlap: CGFloat,
        preserving scrollSnapshots: [ScrollSnapshot]
    ) {
        let clampedOverlap = min(max(0, overlap), max(0, view.bounds.height))
        keyboardOverlap = clampedOverlap
        let bounds = view.bounds
        let composerHeight = measuredComposerHeight(width: bounds.width)
        let composerBottom = bounds.maxY - clampedOverlap
        let composerTop = max(bounds.minY, composerBottom - composerHeight)

        transcriptHostingController.view.frame = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, composerTop - bounds.minY)
        )
        composerHostingController.view.frame = CGRect(
            x: bounds.minX,
            y: composerTop,
            width: bounds.width,
            height: composerHeight
        )
        transcriptHostingController.view.layoutIfNeeded()
        composerHostingController.view.layoutIfNeeded()
        restoreKeyboardViewports(scrollSnapshots)
        #if DEBUG
        updateKeyboardDebugValues(overlap: overlap)
        #endif
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

    private func restoreKeyboardViewports(_ scrollSnapshots: [ScrollSnapshot]) {
        guard !scrollSnapshots.isEmpty, !isRestoringKeyboardViewport else { return }
        isRestoringKeyboardViewport = true
        defer { isRestoringKeyboardViewport = false }
        for (scrollView, snapshot) in scrollSnapshots {
            scrollView.restoreKeyboardViewport(snapshot)
        }
    }

    private func trackedScrollSnapshots() -> [ScrollSnapshot] {
        trackedTranscriptTables(in: transcriptHostingController.view).map { tableView in
            (scrollView: tableView, snapshot: tableView.keyboardViewportSnapshot())
        }
    }

    private func setKeyboardViewportExternallyDriven(_ isDriven: Bool, for scrollSnapshots: [ScrollSnapshot]) {
        for (scrollView, _) in scrollSnapshots {
            scrollView.isKeyboardViewportExternallyDriven = isDriven
        }
    }

    private func keyboardLayoutGuideOverlap() -> CGFloat {
        let guideFrame = view.keyboardLayoutGuide.layoutFrame
        guard !guideFrame.isNull, !guideFrame.isEmpty else { return 0 }
        return max(0, view.bounds.maxY - guideFrame.minY)
    }

    #if DEBUG
    private func updateKeyboardDebugValues(overlap: CGFloat) {
        let guideOverlap = keyboardLayoutGuideOverlap()
        let composerFrame = frameInWindow(for: composerHostingController.view)
        let composerPresentationFrame = keyboardFrameAnimation == nil
            ? composerFrame
            : presentationFrameInWindow(for: composerHostingController.view) ?? composerFrame
        let animationProgress = currentKeyboardFrameAnimationProgress()
        for tableView in trackedTranscriptTables(in: transcriptHostingController.view) {
            tableView.keyboardDebugEventCount = keyboardDebugEventCount
            tableView.keyboardDebugOverlap = overlap
            tableView.keyboardDebugGuideOverlap = guideOverlap
            tableView.keyboardDebugBottomConstraint = -overlap
            tableView.keyboardDebugComposerMinY = composerFrame?.minY ?? 0
            tableView.keyboardDebugComposerPresentationMinY = composerPresentationFrame?.minY ?? 0
            tableView.keyboardDebugAnimationID = keyboardTransitionID
            tableView.keyboardDebugAnimationActive = keyboardFrameAnimation != nil
            tableView.keyboardDebugAnimationProgress = animationProgress
            tableView.keyboardDebugTransitionDuration = keyboardDebugTransitionDuration
            tableView.recordKeyboardAnimationPresentationGap()
            tableView.updateDebugAccessibilityValue()
        }
    }

    private func frameInWindow(for targetView: UIView) -> CGRect? {
        guard let window = targetView.window else { return nil }
        return targetView.convert(targetView.bounds, to: window)
    }

    private func presentationFrameInWindow(for targetView: UIView) -> CGRect? {
        guard let window = targetView.window,
              let superview = targetView.superview,
              let presentationLayer = targetView.layer.presentation()
        else { return nil }
        return superview.layer.convert(presentationLayer.frame, to: window.layer)
    }
    #endif

    private func updateComposerVisibility() {
        guard isViewLoaded else { return }
        composerHostingController.view.isHidden = !showsComposer
        layoutChatGeometry(overlap: keyboardOverlap, preserving: activeKeyboardScrollSnapshots)
    }

    @objc private func handleDismissTap() {
        view.window?.endEditing(true)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func trackedTranscriptTables(in view: UIView) -> [ChatTranscriptUITableView] {
        var tables: [ChatTranscriptUITableView] = []
        if let table = view as? ChatTranscriptUITableView {
            tables.append(table)
        }
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
