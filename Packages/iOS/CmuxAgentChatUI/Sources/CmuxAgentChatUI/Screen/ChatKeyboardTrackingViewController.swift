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

    private let transcriptClipView = UIView(frame: .zero)
    private let composerBackgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let transcriptHostingController: UIHostingController<Transcript>
    private let composerHostingController: UIHostingController<Composer>
    private var composerHeightConstraint: NSLayoutConstraint?
    private var composerBottomConstraint: NSLayoutConstraint?
    private var transcriptHeightConstraint: NSLayoutConstraint?

    private var keyboardOverlap: CGFloat = 0
    private var keyboardTransitionID = 0
    private var lastKeyboardTransitionDuration: TimeInterval = 0.3833
    private var isKeyboardAnimationActive = false
    private var keyboardAnimationStartOverlap: CGFloat = 0
    private var keyboardAnimationTargetOverlap: CGFloat = 0
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

        transcriptClipView.backgroundColor = .clear
        transcriptClipView.clipsToBounds = true
        transcriptClipView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcriptClipView)

        addChild(transcriptHostingController)
        transcriptHostingController.view.backgroundColor = .clear
        transcriptHostingController.safeAreaRegions = .container
        transcriptHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        transcriptClipView.addSubview(transcriptHostingController.view)

        composerBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        composerBackgroundView.isUserInteractionEnabled = false
        composerBackgroundView.clipsToBounds = true
        view.addSubview(composerBackgroundView)

        addChild(composerHostingController)
        composerHostingController.view.backgroundColor = .clear
        composerHostingController.safeAreaRegions = .container
        composerHostingController.sizingOptions = [.intrinsicContentSize]
        composerHostingController.view.translatesAutoresizingMaskIntoConstraints = false
        composerHostingController.view.setContentHuggingPriority(.required, for: .vertical)
        composerHostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(composerHostingController.view)
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
        let composerBottomConstraint = composerHostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        let transcriptHeightConstraint = transcriptHostingController.view.heightAnchor.constraint(equalToConstant: 0)
        self.composerHeightConstraint = composerHeightConstraint
        self.composerBottomConstraint = composerBottomConstraint
        self.transcriptHeightConstraint = transcriptHeightConstraint

        NSLayoutConstraint.activate([
            transcriptClipView.topAnchor.constraint(equalTo: view.topAnchor),
            transcriptClipView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcriptClipView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcriptClipView.bottomAnchor.constraint(equalTo: composerHostingController.view.topAnchor),

            transcriptHostingController.view.leadingAnchor.constraint(equalTo: transcriptClipView.leadingAnchor),
            transcriptHostingController.view.trailingAnchor.constraint(equalTo: transcriptClipView.trailingAnchor),
            transcriptHostingController.view.bottomAnchor.constraint(equalTo: transcriptClipView.bottomAnchor),
            transcriptHeightConstraint,

            composerBackgroundView.topAnchor.constraint(equalTo: composerHostingController.view.topAnchor),
            composerBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            composerHostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerHostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        if abs(keyboardOverlap - overlap) <= 0.5, !isKeyboardAnimationActive {
            return
        }
        let effectiveDuration = effectiveKeyboardTransitionDuration(for: transition, targetOverlap: overlap)
        #if DEBUG
        keyboardDebugTransitionDuration = effectiveDuration
        keyboardDebugEventCount += 1
        updateKeyboardDebugValues(overlap: overlap)
        #endif
        keyboardTransitionID &+= 1
        let transitionID = keyboardTransitionID
        startKeyboardTracking(
            from: keyboardOverlap,
            to: overlap,
            transition: transition,
            duration: effectiveDuration,
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
    }

    private func stopKeyboardAnimation(removeAnimations: Bool) {
        isKeyboardAnimationActive = false
        if removeAnimations {
            transcriptClipView.layer.removeAllAnimations()
            transcriptHostingController.view.layer.removeAllAnimations()
            composerBackgroundView.layer.removeAllAnimations()
            composerHostingController.view.layer.removeAllAnimations()
        }
    }

    private func updateMeasuredGeometryConstants() {
        let bounds = view.bounds
        let composerHeight = measuredComposerHeight(width: bounds.width)
        let fullTranscriptHeight = max(0, bounds.height - composerHeight)
        updateConstraint(composerHeightConstraint, to: composerHeight)
        updateConstraint(transcriptHeightConstraint, to: fullTranscriptHeight)
    }

    private func applyKeyboardOverlap(_ overlap: CGFloat) {
        let clampedOverlap = min(max(0, overlap), max(0, view.bounds.height))
        keyboardOverlap = clampedOverlap
        updateConstraint(composerBottomConstraint, to: -clampedOverlap)
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

    private func keyboardLayoutGuideOverlap() -> CGFloat {
        let guideFrame = view.keyboardLayoutGuide.layoutFrame
        guard !guideFrame.isNull, !guideFrame.isEmpty else { return 0 }
        return max(0, view.bounds.maxY - guideFrame.minY)
    }

    #if DEBUG
    private func updateKeyboardDebugValues(overlap: CGFloat) {
        let guideOverlap = keyboardLayoutGuideOverlap()
        let composerFrame = frameInWindow(for: composerHostingController.view)
        let composerPresentationFrame = !isKeyboardAnimationActive
            ? composerFrame
            : presentationFrameInWindow(for: composerHostingController.view) ?? composerFrame
        let animationProgress = clampedKeyboardAnimationProgress(overlap: overlap)
        for tableView in trackedTranscriptTables(in: transcriptHostingController.view) {
            tableView.keyboardDebugEventCount = keyboardDebugEventCount
            tableView.keyboardDebugOverlap = overlap
            tableView.keyboardDebugGuideOverlap = guideOverlap
            tableView.keyboardDebugBottomConstraint = -overlap
            tableView.keyboardDebugComposerMinY = composerFrame?.minY ?? 0
            tableView.keyboardDebugComposerPresentationMinY = composerPresentationFrame?.minY ?? 0
            tableView.keyboardDebugAnimationID = keyboardTransitionID
            tableView.keyboardDebugAnimationActive = isKeyboardAnimationActive
            tableView.keyboardDebugAnimationProgress = animationProgress
            tableView.keyboardDebugTransitionDuration = keyboardDebugTransitionDuration
            tableView.recordKeyboardAnimationPresentationGap()
            tableView.updateDebugAccessibilityValue()
        }
    }

    private func clampedKeyboardAnimationProgress(overlap: CGFloat) -> CGFloat {
        guard keyboardDebugTransitionDuration > 0, isKeyboardAnimationActive else {
            return keyboardOverlap > 0 ? 1 : 0
        }
        let delta = keyboardAnimationTargetOverlap - keyboardAnimationStartOverlap
        guard abs(delta) > 0.5 else { return 1 }
        return min(max((overlap - keyboardAnimationStartOverlap) / delta, 0), 1)
    }

    private func frameInWindow(for targetView: UIView) -> CGRect? {
        guard let window = targetView.window else { return nil }
        return targetView.convert(targetView.bounds, to: window)
    }

    private func presentationFrameInWindow(for targetView: UIView) -> CGRect? {
        guard let window = targetView.window
        else { return nil }
        let sourceLayer = targetView.layer.presentation() ?? targetView.layer
        let targetLayer = window.layer.presentation() ?? window.layer
        return sourceLayer.convert(targetView.bounds, to: targetLayer)
    }
    #endif

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
