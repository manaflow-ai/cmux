#if canImport(UIKit)
import CmuxAgentChat
import UIKit

/// Host controller for the chat lab. It is the first responder that vends the
/// composer as the keyboard's `inputAccessoryView`, hosts the inverted message
/// list as a child, and keeps the list's bottom inset glued to the composer:
///
/// - Resting transitions (show/hide, snap-back) animate the inset with the
///   keyboard's own duration and curve, read from the notification `userInfo`.
/// - The interactive dismiss drag is driven by a `CADisplayLink` in `.common`
///   mode that reads the composer's presentation-layer top each frame, because
///   the keyboard frame notifications do not fire during the drag.
///
/// One scalar (the composer top) feeds both the composer position (free, it is
/// the accessory) and the list inset, so they can never disagree.
@MainActor
final class ChatLabViewController: UIViewController {
    private let store: ChatConversationStore
    private let list: MessageListController
    private let composer = ComposerBar()
    private let typingLabel = UILabel()
    private var typingBottomConstraint: NSLayoutConstraint!

    private var keyboardVisible = false
    private var dragLink: CADisplayLink?

    #if DEBUG
    private let probe = ChatLabMetricsProbe()
    #endif

    init(store: ChatConversationStore) {
        self.store = store
        self.list = MessageListController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: First responder / accessory

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { composer }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(list.view)
        NSLayoutConstraint.activate([
            list.view.topAnchor.constraint(equalTo: view.topAnchor),
            list.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            list.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        list.didMove(toParent: self)

        composer.onSend = { [weak self] text in
            guard let self else { return }
            Task { await store.send(text: text) }
        }
        composer.onHeightChange = { [weak self] in
            guard let self else { return }
            composer.invalidateIntrinsicContentSize()
            applyOverlapForResting(animated: true)
            #if DEBUG
            probe.noteComposerHeight(composer.resolvedHeight)
            #endif
        }

        list.onBeginDragging = { [weak self] _ in self?.beginDragSync() }
        list.onEndDragging = { [weak self] _ in self?.endDragSync() }

        typingLabel.text = "Agent is typing…"
        typingLabel.font = .preferredFont(forTextStyle: .footnote)
        typingLabel.textColor = .secondaryLabel
        typingLabel.translatesAutoresizingMaskIntoConstraints = false
        typingLabel.isHidden = true
        view.addSubview(typingLabel)
        typingBottomConstraint = typingLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -56)
        NSLayoutConstraint.activate([
            typingLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            typingBottomConstraint,
        ])

        #if DEBUG
        view.addSubview(probe.probeView)
        #endif

        observeAgentState()
        registerKeyboardNotifications()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Dock the composer (keyboard stays down until the user taps the field).
        becomeFirstResponder()
        applyOverlapForResting(animated: false)
    }

    // MARK: Keyboard notifications (resting transitions)

    private func registerKeyboardNotifications() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ note: Notification) { keyboardVisible = true }
    @objc private func keyboardWillHide(_ note: Notification) { keyboardVisible = false }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let rawCurve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        let overlap = overlapFromKeyboardTopScreen(endFrame.minY)
        applyOverlap(overlap, animated: duration > 0, duration: duration, rawCurve: rawCurve)
    }

    // MARK: Interactive drag sync

    private func beginDragSync() {
        guard keyboardVisible, dragLink == nil else { return }
        #if DEBUG
        probe.reset()
        #endif
        let link = CADisplayLink(target: self, selector: #selector(dragTick))
        link.add(to: .main, forMode: .common)
        dragLink = link
    }

    private func endDragSync() {
        dragLink?.invalidate()
        dragLink = nil
    }

    @objc private func dragTick() {
        guard let composerTopScreen = screenFrame(of: composer, usePresentation: true)?.minY,
              let listBottomScreen = screenFrame(of: list.view, usePresentation: false)?.maxY
        else { return }
        // Drive the list inset from the composer's CURRENT presentation, then
        // measure the residual gap. A correctly-synced frame leaves this within
        // sub-pixel; if the link ever stopped driving the inset (the old
        // notification-frozen bug), the composer would move while the inset
        // stayed put and the residual would blow up to the full keyboard travel.
        let dynamicOverlap = listBottomScreen - composerTopScreen
        let overlap = max(restingOverlap, dynamicOverlap)
        applyOverlap(overlap, animated: false, duration: 0, rawCurve: 0)
        #if DEBUG
        // Only sample while the keyboard is meaningfully raised; below the
        // resting position the overlap intentionally clamps and the residual is
        // not a tracking error.
        if dynamicOverlap > restingOverlap {
            probe.record(
                composerTopScreen: composerTopScreen,
                listBottomScreen: listBottomScreen,
                appliedInset: list.collectionView.contentInset.top
            )
        }
        #endif
    }

    // MARK: Overlap math

    /// Inset that keeps the list's content above the docked composer when the
    /// keyboard is down.
    private var restingOverlap: CGFloat {
        composer.resolvedHeight + view.safeAreaInsets.bottom
    }

    private func overlapFromKeyboardTopScreen(_ keyboardTopScreen: CGFloat) -> CGFloat {
        guard let listBottomScreen = screenFrame(of: list.view, usePresentation: false)?.maxY else {
            return restingOverlap
        }
        return max(restingOverlap, listBottomScreen - keyboardTopScreen)
    }

    private func applyOverlapForResting(animated: Bool) {
        applyOverlap(restingOverlap, animated: animated, duration: 0.2, rawCurve: Int(UIView.AnimationCurve.easeInOut.rawValue))
    }

    private func applyOverlap(_ overlap: CGFloat, animated: Bool, duration: Double, rawCurve: Int) {
        let collection = list.collectionView
        let oldInset = collection.contentInset.top
        let delta = KeyboardSyncSolver.offsetCompensation(previousInset: oldInset, newInset: overlap)
        let pinned = KeyboardSyncSolver.isPinnedToBottom(
            contentOffsetY: collection.contentOffset.y,
            topInset: oldInset
        )

        let apply = {
            collection.contentInset.top = overlap
            collection.verticalScrollIndicatorInsets.top = overlap
            if pinned {
                collection.contentOffset.y = -overlap
            } else {
                collection.contentOffset.y += delta
            }
            self.typingBottomConstraint.constant = -overlap - 4
            self.view.layoutIfNeeded()
        }

        if animated {
            let options = UIView.AnimationOptions(rawValue: UInt(rawCurve) << 16)
            UIView.animate(withDuration: duration, delay: 0, options: options, animations: apply)
        } else {
            apply()
        }
    }

    // MARK: Agent state

    private func observeAgentState() {
        withObservationTracking {
            let working: Bool
            if case .working = store.agentState { working = true } else { working = false }
            typingLabel.isHidden = !working
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAgentState() }
        }
    }

    // MARK: Cross-window geometry

    /// A view's frame in screen coordinates, optionally from its presentation
    /// layer. Handles the composer living in the keyboard's own window.
    private func screenFrame(of view: UIView, usePresentation: Bool) -> CGRect? {
        guard let window = view.window, let superview = view.superview else { return nil }
        let rect = usePresentation ? (view.layer.presentation()?.frame ?? view.frame) : view.frame
        let inWindow = superview.convert(rect, to: nil)
        return window.screen.coordinateSpace.convert(inWindow, from: window.coordinateSpace)
    }
}
#endif
