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
    private let jumpButton = UIButton(type: .system)
    private var jumpButtonBottomConstraint: NSLayoutConstraint!

    private var keyboardVisible = false
    private var dragLink: CADisplayLink?
    /// True while the user's finger is on the list during an interactive
    /// dismiss; false once lifted (the link keeps running through the release
    /// spring until the composer settles).
    private var fingerDown = false
    /// While true, the display link owns the list inset and the keyboard
    /// notifications must not also animate it (they would fight the link).
    private var interactiveSyncActive = false
    private var lastComposerTopScreen: CGFloat = 0
    private var settledFrames = 0

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
            probe.noteComposerHeight(composer.barContentHeight)
            #endif
        }

        list.onBeginDragging = { [weak self] _ in self?.beginDragSync() }
        list.onEndDragging = { [weak self] _ in self?.fingerLifted() }
        list.onScroll = { [weak self] scrollView in self?.updateJumpButton(scrollView) }

        // Tap anywhere in the list (a message or the negative space) dismisses
        // the keyboard. cancelsTouchesInView is false so it never swallows a
        // scroll or a future cell tap.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleListTap))
        tap.cancelsTouchesInView = false
        list.collectionView.addGestureRecognizer(tap)

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

        configureJumpButton()

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

    @objc private func handleListTap() {
        guard composer.editor.isFirstResponder else { return }
        // Resign the text view, then re-become first responder so the accessory
        // bar stays docked at the bottom instead of disappearing.
        composer.editor.resignFirstResponder()
        becomeFirstResponder()
    }

    @objc private func keyboardWillShow(_ note: Notification) { keyboardVisible = true }
    @objc private func keyboardWillHide(_ note: Notification) { keyboardVisible = false }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        // The display link owns the inset throughout an interactive drag AND its
        // release spring; ignore the commit/snap-back notification so we don't
        // run a second, competing animation on the same inset.
        guard !interactiveSyncActive else { return }
        guard let info = note.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let rawCurve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        let overlap = overlapFromKeyboardTopScreen(endFrame.minY)
        applyOverlap(overlap, animated: duration > 0, adjustOffset: true, duration: duration, rawCurve: rawCurve)
    }

    // MARK: Interactive drag sync
    //
    // The link runs from drag-begin until the composer settles — crucially
    // INCLUDING the release phase, where UIKit springs the keyboard to its
    // committed position (dismissed or snapped back). By reading the composer's
    // presentation layer every frame we follow that real spring exactly, in
    // lockstep, with no curve to match and nothing to fight.

    private func beginDragSync() {
        guard keyboardVisible else { return }
        fingerDown = true
        guard dragLink == nil else { return }
        interactiveSyncActive = true
        settledFrames = 0
        lastComposerTopScreen = screenFrame(of: composer, usePresentation: true)?.minY ?? 0
        #if DEBUG
        probe.reset()
        #endif
        let link = CADisplayLink(target: self, selector: #selector(dragTick))
        link.add(to: .main, forMode: .common)
        dragLink = link
    }

    /// Finger lifted: the keyboard now springs to its committed position. Keep
    /// the link running so the inset rides that spring; stop once it settles.
    private func fingerLifted() {
        fingerDown = false
    }

    private func stopDragSync() {
        dragLink?.invalidate()
        dragLink = nil
        interactiveSyncActive = false
    }

    @objc private func dragTick() {
        guard let composerTopScreen = screenFrame(of: composer, usePresentation: true)?.minY,
              let listBottomScreen = screenFrame(of: list.view, usePresentation: false)?.maxY
        else { return }
        let dynamicOverlap = listBottomScreen - composerTopScreen
        let overlap = max(restingOverlap, dynamicOverlap)
        // Inset only: the scroll view's pan owns contentOffset during the drag,
        // and the keyboard's own spring owns the composer during the release, so
        // we never write offset and never run a competing animation here. No
        // layoutIfNeeded — an inset change applies immediately.
        applyOverlap(overlap, animated: false, adjustOffset: false, duration: 0, rawCurve: 0)
        #if DEBUG
        if dynamicOverlap > restingOverlap {
            probe.record(
                composerTopScreen: composerTopScreen,
                listBottomScreen: listBottomScreen,
                appliedInset: list.collectionView.contentInset.top
            )
        }
        #endif
        // After the finger lifts, watch the release spring: once the composer
        // stops moving for a few frames, the spring has settled — stop the link.
        if !fingerDown {
            if abs(composerTopScreen - lastComposerTopScreen) < 0.5 {
                settledFrames += 1
                if settledFrames >= 3 { stopDragSync() }
            } else {
                settledFrames = 0
            }
        }
        lastComposerTopScreen = composerTopScreen
    }

    // MARK: Overlap math

    /// Inset that keeps the list's content above the docked composer when the
    /// keyboard is down: the bar's content height plus the home-indicator inset.
    private var restingOverlap: CGFloat {
        composer.barContentHeight + view.safeAreaInsets.bottom
    }

    private func overlapFromKeyboardTopScreen(_ keyboardTopScreen: CGFloat) -> CGFloat {
        guard let listBottomScreen = screenFrame(of: list.view, usePresentation: false)?.maxY else {
            return restingOverlap
        }
        return max(restingOverlap, listBottomScreen - keyboardTopScreen)
    }

    private func applyOverlapForResting(animated: Bool) {
        applyOverlap(restingOverlap, animated: animated, adjustOffset: true, duration: 0.2, rawCurve: Int(UIView.AnimationCurve.easeInOut.rawValue))
    }

    /// Applies the list's bottom inset (and, for resting transitions, keeps the
    /// content pinned). `adjustOffset` is false during the interactive drag, so
    /// we never fight the scroll view's own pan.
    private func applyOverlap(_ overlap: CGFloat, animated: Bool, adjustOffset: Bool, duration: Double, rawCurve: Int) {
        let collection = list.collectionView
        let oldInset = collection.contentInset.top
        let pinned = KeyboardSyncSolver.isPinnedToBottom(
            contentOffsetY: collection.contentOffset.y,
            topInset: oldInset
        )

        let apply = {
            collection.contentInset.top = overlap
            collection.verticalScrollIndicatorInsets.top = overlap
            // Only the at-newest case moves the offset: pin the newest message
            // above the composer. When scrolled up, an inset change alone does
            // not move visible content, so leaving the offset keeps the reader
            // exactly where they are (no jump).
            if adjustOffset, pinned {
                collection.contentOffset.y = -overlap
            }
            self.typingBottomConstraint.constant = -overlap - 4
            self.jumpButtonBottomConstraint.constant = -overlap - 10
        }

        if animated {
            let options = UIView.AnimationOptions(rawValue: UInt(rawCurve) << 16)
            UIView.animate(withDuration: duration, delay: 0, options: options) {
                apply()
                self.view.layoutIfNeeded()
            }
        } else {
            // No layoutIfNeeded on the per-frame drag path; inset/offset writes
            // take effect immediately and a full layout pass each frame jitters.
            apply()
        }
    }

    // MARK: Jump-to-latest

    private func configureJumpButton() {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: "chevron.down")
        config.baseBackgroundColor = .secondarySystemBackground
        config.baseForegroundColor = .label
        jumpButton.configuration = config
        jumpButton.accessibilityIdentifier = "ChatLabJumpToLatest"
        jumpButton.accessibilityLabel = "Jump to latest"
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.alpha = 0
        jumpButton.isHidden = true
        jumpButton.layer.shadowColor = UIColor.black.cgColor
        jumpButton.layer.shadowOpacity = 0.15
        jumpButton.layer.shadowRadius = 6
        jumpButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        jumpButton.addTarget(self, action: #selector(scrollToNewest), for: .touchUpInside)
        view.addSubview(jumpButton)
        jumpButtonBottomConstraint = jumpButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -restingOverlap - 10)
        NSLayoutConstraint.activate([
            jumpButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            jumpButton.widthAnchor.constraint(equalToConstant: 38),
            jumpButton.heightAnchor.constraint(equalToConstant: 38),
            jumpButtonBottomConstraint,
        ])
    }

    /// Shows the pill whenever the user has scrolled away from the newest
    /// message; hides it at the bottom. A new message arriving while scrolled up
    /// keeps the pill visible (the reader's position is untouched).
    private func updateJumpButton(_ scrollView: UIScrollView) {
        let atBottom = KeyboardSyncSolver.isPinnedToBottom(
            contentOffsetY: scrollView.contentOffset.y,
            topInset: scrollView.contentInset.top,
            tolerance: 24
        )
        let shouldShow = !atBottom
        guard shouldShow != (jumpButton.alpha > 0.5) else { return }
        if shouldShow { jumpButton.isHidden = false }
        UIView.animate(withDuration: 0.2) {
            self.jumpButton.alpha = shouldShow ? 1 : 0
        } completion: { _ in
            if !shouldShow { self.jumpButton.isHidden = true }
        }
    }

    @objc private func scrollToNewest() {
        let collection = list.collectionView
        // Inverted list: the visual bottom (newest) is the minimum offset.
        collection.setContentOffset(CGPoint(x: 0, y: -collection.contentInset.top), animated: true)
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
