#if canImport(UIKit)
import CmuxAgentChat
import UIKit

/// Host controller for the chat lab. It is the first responder that vends the
/// composer as the keyboard's `inputAccessoryView`, hosts the inverted message
/// list as a child, and keeps the list's bottom inset glued to the composer.
///
/// All keyboard/scroll decisions live in ``KeyboardSyncMachine`` (a pure,
/// host-tested reducer). This controller is the thin adapter: it feeds UIKit
/// signals in as events and performs the effects the machine returns. The two
/// inset clocks are kept mutually exclusive by the machine, not by ad hoc flags:
///
/// - Resting transitions (show/hide, snap-back, docked height change) animate
///   the inset with the keyboard's own duration and curve from the notification.
/// - The interactive dismiss drag and its release spring are driven by a
///   `CADisplayLink` in `.common` mode that reads the composer's
///   presentation-layer top each frame, because the keyboard frame notifications
///   do not fire during the drag.
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

    /// The single source of truth for keyboard/scroll sync. Mutated only here, on
    /// the main actor.
    private var machine = KeyboardSyncMachine()
    /// The per-frame clock for the interactive drag and its release spring. Owned
    /// while the machine is in `dragging`/`releasing`.
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
        composer.onHeightChange = { [weak self] in self?.dispatch(.composerHeightChanged) }

        list.onBeginDragging = { [weak self] _ in self?.dispatch(.beganDragging) }
        list.onEndDragging = { [weak self] _ in self?.dispatch(.endedDragging) }
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

    // MARK: Machine plumbing

    /// Feed one UIKit signal into the machine and perform whatever it returns.
    /// `note` carries the keyboard animation timing when the event came from a
    /// keyboard notification.
    private func dispatch(_ event: KeyboardSyncEvent, note: Notification? = nil) {
        perform(machine.handle(event), note: note)
    }

    private func perform(_ effects: [KeyboardSyncEffect], note: Notification?) {
        for effect in effects {
            switch effect {
            case .startLink:
                startDragLink()
            case .stopLink:
                stopDragLink()
            case .applyAnimated(let target):
                applyAnimatedInset(to: target, note: note)
            case .applyPerFrame(let composerTop):
                applyPerFrameInset(composerTop: composerTop)
            case .reconcile:
                reconcileInset()
            case .invalidateComposerIntrinsicSize:
                composer.invalidateIntrinsicContentSize()
                #if DEBUG
                probe.noteComposerHeight(composer.barContentHeight)
                #endif
            case .resignTextView:
                composer.editor.resignFirstResponder()
            case .dockAccessory:
                // Re-become first responder so the accessory bar stays docked at
                // the bottom instead of vanishing with the keyboard.
                becomeFirstResponder()
            case .ignoreKeyboardNotification:
                break
            }
        }
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
        dispatch(.tapToDismiss)
    }

    @objc private func keyboardWillShow(_ note: Notification) { dispatch(.keyboardWillShow, note: note) }
    @objc private func keyboardWillHide(_ note: Notification) { dispatch(.keyboardWillHide, note: note) }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        dispatch(.keyboardFrameWillChange(keyboardTop: endFrame.minY), note: note)
    }

    // MARK: Interactive drag sync
    //
    // The link runs from drag-begin until the composer settles — crucially
    // INCLUDING the release phase, where UIKit springs the keyboard to its
    // committed position (dismissed or snapped back). By reading the composer's
    // presentation layer every frame we follow that real spring exactly, in
    // lockstep, with no curve to match and nothing to fight. Lifecycle is driven
    // by the machine's `startLink`/`stopLink` effects.

    private func startDragLink() {
        #if DEBUG
        probe.reset()
        #endif
        guard dragLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(dragTick))
        link.add(to: .main, forMode: .common)
        dragLink = link
    }

    private func stopDragLink() {
        dragLink?.invalidate()
        dragLink = nil
    }

    @objc private func dragTick() {
        guard let composerTop = screenFrame(of: composer, usePresentation: true)?.minY else { return }
        dispatch(.linkTick(composerTop: composerTop))
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

    /// Animated inset for a resting transition: the keyboard's own duration/curve
    /// when the event came from a keyboard notification, a short default for a
    /// docked composer height change.
    private func applyAnimatedInset(to target: KeyboardInsetTarget, note: Notification?) {
        let overlap: CGFloat
        switch target {
        case .keyboardTop(let top): overlap = overlapFromKeyboardTopScreen(top)
        case .resting: overlap = restingOverlap
        }
        let info = note?.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.2
        let rawCurve = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? Int(UIView.AnimationCurve.easeInOut.rawValue)
        applyOverlap(overlap, animated: duration > 0, adjustOffset: true, duration: duration, rawCurve: rawCurve)
    }

    /// Per-frame inset during the interactive drag/release: read the list bottom
    /// live and glue the inset to the composer's presentation top. No offset write
    /// (the pan / spring own it) and no animation.
    private func applyPerFrameInset(composerTop: CGFloat) {
        guard let listBottomScreen = screenFrame(of: list.view, usePresentation: false)?.maxY else { return }
        let dynamicOverlap = listBottomScreen - composerTop
        let overlap = max(restingOverlap, dynamicOverlap)
        applyOverlap(overlap, animated: false, adjustOffset: false, duration: 0, rawCurve: 0)
        #if DEBUG
        if dynamicOverlap > restingOverlap {
            probe.record(
                composerTopScreen: composerTop,
                listBottomScreen: listBottomScreen,
                appliedInset: list.collectionView.contentInset.top
            )
        }
        #endif
    }

    /// Final unanimated snap when a release ends. The committed keyboard frame was
    /// ignored while the link owned the inset, so we recompute the settled target
    /// from live geometry (composer model frame == presentation frame now) and pin.
    private func reconcileInset() {
        guard let composerTop = screenFrame(of: composer, usePresentation: false)?.minY,
              let listBottomScreen = screenFrame(of: list.view, usePresentation: false)?.maxY
        else { return }
        let overlap = max(restingOverlap, listBottomScreen - composerTop)
        applyOverlap(overlap, animated: false, adjustOffset: true, duration: 0, rawCurve: 0)
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
