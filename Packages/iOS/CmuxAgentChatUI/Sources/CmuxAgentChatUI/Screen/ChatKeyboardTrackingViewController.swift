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
    private var composerBottomConstraint: NSLayoutConstraint?
    private var composerZeroHeightConstraint: NSLayoutConstraint?
    private var activeKeyboardScrollSnapshots: [ScrollSnapshot] = []
    private var isRestoringKeyboardViewport = false
    private var keyboardOverlap: CGFloat = 0
    private var keyboardTransitionID = 0
    private var keyboardFrameAnimation: ChatKeyboardFrameAnimation?
    private var keyboardFrameDisplayLink: CADisplayLink?
    #if DEBUG
    private var keyboardDebugEventCount = 0
    private var keyboardDebugTransitionDuration: TimeInterval = 0
    #endif
    private var keyboardObservers: [ChatKeyboardNotificationToken] = []
    private var keyboardGuideDisplayLink: CADisplayLink?
    private var keyboardGuideTrackingFramesRemaining = 0
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
        transcriptHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcriptHostingController.view)

        addChild(composerHostingController)
        composerHostingController.view.backgroundColor = .clear
        composerHostingController.safeAreaRegions = .container
        composerHostingController.sizingOptions = [.intrinsicContentSize]
        composerHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        composerHostingController.view.setContentHuggingPriority(.required, for: .vertical)
        composerHostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(composerHostingController.view)

        let zeroHeight = composerHostingController.view.heightAnchor.constraint(equalToConstant: 0)
        composerZeroHeightConstraint = zeroHeight

        let bottomConstraint = composerHostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        composerBottomConstraint = bottomConstraint

        NSLayoutConstraint.activate([
            transcriptHostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcriptHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcriptHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcriptHostingController.view.bottomAnchor.constraint(equalTo: composerHostingController.view.topAnchor),

            composerHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ])

        transcriptHostingController.didMove(toParent: self)
        composerHostingController.didMove(toParent: self)
        updateComposerVisibility()

        for name in [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillHideNotification,
            UITextField.textDidBeginEditingNotification,
            UITextField.textDidEndEditingNotification,
            UITextView.textDidBeginEditingNotification,
            UITextView.textDidEndEditingNotification,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let transition = MobileKeyboardTransition(notification: notification) {
                    Task { @MainActor [weak self, transition] in
                        self?.keyboardWillChangeFrame(transition)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.startKeyboardGuideTracking()
                    }
                }
            }
            keyboardObservers.append(ChatKeyboardNotificationToken(observer))
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installDismissTapIfNeeded()
        #if DEBUG
        updateKeyboardDebugValues(overlap: keyboardOverlap)
        #endif
        restoreKeyboardViewports(activeKeyboardScrollSnapshots)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopKeyboardFrameAnimation()
        stopKeyboardGuideTracking(clearSnapshots: true)
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
        #if DEBUG
        keyboardDebugTransitionDuration = transition.duration
        keyboardDebugEventCount += 1
        updateKeyboardDebugValues(overlap: overlap)
        #endif
        if overlap > 0 || keyboardOverlap > 0 {
            stopKeyboardGuideTracking(clearSnapshots: false)
        }
        let scrollSnapshots = activeKeyboardScrollSnapshots.isEmpty
            ? trackedScrollSnapshots()
            : activeKeyboardScrollSnapshots
        activeKeyboardScrollSnapshots = scrollSnapshots
        keyboardTransitionID &+= 1
        let transitionID = keyboardTransitionID
        startKeyboardFrameAnimation(
            to: overlap,
            transition: transition,
            preserving: scrollSnapshots,
            transitionID: transitionID
        )
    }

    private func startKeyboardFrameAnimation(
        to targetOverlap: CGFloat,
        transition: MobileKeyboardTransition,
        preserving scrollSnapshots: [ScrollSnapshot],
        transitionID: Int
    ) {
        stopKeyboardFrameAnimation()

        let startOverlap = keyboardOverlap
        guard transition.duration > 0, abs(targetOverlap - startOverlap) > 0.5 else {
            keyboardFrameAnimation = nil
            keyboardProgressView.center = CGPoint(x: 1, y: 0)
            applyKeyboardOverlap(targetOverlap, preserving: scrollSnapshots)
            activeKeyboardScrollSnapshots = []
            return
        }

        keyboardProgressView.center = CGPoint(x: 0, y: 0)
        keyboardFrameAnimation = ChatKeyboardFrameAnimation(
            id: transitionID,
            startOverlap: startOverlap,
            targetOverlap: targetOverlap,
            scrollSnapshots: scrollSnapshots
        )
        startKeyboardFrameDisplayLink()

        transition.animate {
            self.keyboardOverlap = targetOverlap
            self.applyKeyboardOverlap(targetOverlap, preserving: scrollSnapshots)
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
        stopKeyboardFrameAnimation()
        keyboardProgressView.center = CGPoint(x: 1, y: 0)
        applyKeyboardOverlap(targetOverlap, preserving: scrollSnapshots)
        activeKeyboardScrollSnapshots = []
    }

    private func stopKeyboardFrameAnimation() {
        keyboardFrameDisplayLink?.invalidate()
        keyboardFrameDisplayLink = nil
        keyboardFrameAnimation = nil
        keyboardProgressView.layer.removeAllAnimations()
    }

    private func currentKeyboardFrameAnimationProgress() -> CGFloat {
        let rawProgress = keyboardProgressView.layer.presentation()?.position.x
            ?? keyboardProgressView.layer.position.x
        return min(max(rawProgress, 0), 1)
    }

    private func startKeyboardFrameDisplayLink() {
        guard keyboardFrameDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(keyboardFrameDisplayLinkDidTick))
        displayLink.add(to: .main, forMode: .common)
        keyboardFrameDisplayLink = displayLink
    }

    @objc private func keyboardFrameDisplayLinkDidTick() {
        guard let animation = keyboardFrameAnimation else {
            keyboardFrameDisplayLink?.invalidate()
            keyboardFrameDisplayLink = nil
            return
        }
        let progress = currentKeyboardFrameAnimationProgress()
        let overlap = animation.startOverlap
            + ((animation.targetOverlap - animation.startOverlap) * progress)
        #if DEBUG
        updateKeyboardDebugValues(overlap: overlap)
        #endif
    }

    private func applyKeyboardOverlap(
        _ overlap: CGFloat,
        preserving scrollSnapshots: [ScrollSnapshot] = []
    ) {
        keyboardOverlap = overlap
        composerBottomConstraint?.constant = -overlap
        view.setNeedsLayout()
        view.layoutIfNeeded()
        transcriptHostingController.view.layoutIfNeeded()
        composerHostingController.view.layoutIfNeeded()
        restoreKeyboardViewports(scrollSnapshots)
        #if DEBUG
        updateKeyboardDebugValues(overlap: overlap)
        #endif
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

    private func startKeyboardGuideTracking() {
        guard view.window != nil else { return }
        guard keyboardFrameAnimation == nil else { return }
        if activeKeyboardScrollSnapshots.isEmpty {
            activeKeyboardScrollSnapshots = trackedScrollSnapshots()
        }
        keyboardGuideTrackingFramesRemaining = 45
        guard keyboardGuideDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(keyboardGuideDisplayLinkDidTick))
        displayLink.add(to: .main, forMode: .common)
        keyboardGuideDisplayLink = displayLink
    }

    private func stopKeyboardGuideTracking(clearSnapshots: Bool) {
        keyboardGuideDisplayLink?.invalidate()
        keyboardGuideDisplayLink = nil
        keyboardGuideTrackingFramesRemaining = 0
        if clearSnapshots {
            activeKeyboardScrollSnapshots = []
        }
    }

    @objc private func keyboardGuideDisplayLinkDidTick() {
        guard view.window != nil else {
            stopKeyboardGuideTracking(clearSnapshots: true)
            return
        }
        let overlap = keyboardLayoutGuideOverlap()
        if abs(overlap - keyboardOverlap) > 0.5 {
            if activeKeyboardScrollSnapshots.isEmpty {
                activeKeyboardScrollSnapshots = trackedScrollSnapshots()
            }
            applyKeyboardOverlap(overlap, preserving: activeKeyboardScrollSnapshots)
        } else {
            #if DEBUG
            updateKeyboardDebugValues(overlap: overlap)
            #endif
        }
        keyboardGuideTrackingFramesRemaining -= 1
        if keyboardGuideTrackingFramesRemaining <= 0 {
            stopKeyboardGuideTracking(clearSnapshots: true)
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
        composerZeroHeightConstraint?.isActive = !showsComposer
        view.setNeedsLayout()
        view.layoutIfNeeded()
        restoreKeyboardViewports(activeKeyboardScrollSnapshots)
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
