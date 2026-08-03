#if os(iOS)
import Accessibility
import CmuxAgentChat
import CmuxMobileToast
import Observation
import UIKit

/// Host-owned storage for the composer draft without a declarative binding dependency.
@MainActor
public struct ChatDraftBinding {
    private let read: @MainActor () -> String
    private let write: @MainActor (String) -> Void

    public init(
        get: @escaping @MainActor () -> String,
        set: @escaping @MainActor (String) -> Void
    ) {
        read = get
        write = set
    }

    public static func constant(_ value: String) -> ChatDraftBinding {
        ChatDraftBinding(get: { value }, set: { _ in })
    }

    var value: String {
        get { read() }
        nonmutating set { write(newValue) }
    }
}

/// Native conversation surface with UIKit-owned navigation and keyboard lifecycles.
@MainActor
public final class ChatViewController: UIViewController {
    private let store: ChatConversationStore
    private let toastCenter: ToastCenter
    private let renderer: ChatMarkdownRenderer
    private let contentCache: ChatContentCache
    private let detailBuilder = ChatBlockDetailBuilder()
    private let providesOwnChrome: Bool
    private let runsStoreTask: Bool
    private let onOpenTerminal: @MainActor () -> Void

    private var draft: ChatDraftBinding
    private var accessoryLeadingShortcuts: [ChatAccessoryShortcut]
    private var accessoryShortcuts: [ChatAccessoryShortcut]
    private var artifactLoader: ChatArtifactLoader
    private var theme: ChatTheme

    private let transcriptView = ChatTranscriptNativeView()
    private lazy var composerView = ChatComposerNativeView(
        configuration: composerConfiguration()
    )
    private lazy var keyboardController = ChatKeyboardTrackingViewController(
        transcriptView: transcriptView,
        composerView: composerView,
        showsComposer: store.agentState != .ended
    )
    private let errorBanner = ChatErrorBannerView()

    private var observationGeneration = 0
    private var storeTask: Task<Void, Never>?
    private var lastAnnouncedRowID: String?
    private var lastErrorBridgeKey: ErrorBridgeKey?

    /// Creates the native chat controller.
    public init(
        store: ChatConversationStore,
        draft: ChatDraftBinding = .constant(""),
        accessoryLeadingShortcuts: [ChatAccessoryShortcut] = [],
        accessoryShortcuts: [ChatAccessoryShortcut] = [],
        artifactLoader: ChatArtifactLoader = .unsupported(),
        theme: ChatTheme = ChatTheme(),
        toastCenter: ToastCenter,
        providesOwnChrome: Bool = true,
        runsStoreTask: Bool = true,
        onOpenTerminal: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.draft = draft
        self.accessoryLeadingShortcuts = accessoryLeadingShortcuts
        self.accessoryShortcuts = accessoryShortcuts
        self.artifactLoader = artifactLoader
        self.theme = theme
        self.toastCenter = toastCenter
        self.providesOwnChrome = providesOwnChrome
        self.runsStoreTask = runsStoreTask
        self.onOpenTerminal = onOpenTerminal
        renderer = ChatMarkdownRenderer()
        contentCache = ChatContentCache()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "ChatScreen"
        edgesForExtendedLayout = [.top, .bottom]
        extendedLayoutIncludesOpaqueBars = true

        addChild(keyboardController)
        keyboardController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardController.view)
        NSLayoutConstraint.activate([
            keyboardController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardController.view.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        keyboardController.didMove(toParent: self)

        errorBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorBanner)
        NSLayoutConstraint.activate([
            errorBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            errorBanner.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            errorBanner.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
        ])
        errorBanner.onDismiss = { [weak self] in self?.store.dismissError() }

        transcriptView.onScrollButtonFrameChanged = { [weak keyboardController] frame in
            keyboardController?.excludedKeyboardDismissFrame = frame
        }
        composerView.onIntrinsicHeightChanged = { [weak keyboardController] in
            keyboardController?.view.setNeedsLayout()
        }
        beginObservation()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if providesOwnChrome {
            configureNavigationChrome()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startStoreTaskIfNeeded()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        storeTask?.cancel()
        storeTask = nil
        errorBanner.cancelAutoDismiss()
    }

    /// Refreshes host-owned presentation inputs without replacing the conversation owner.
    public func update(
        draft: ChatDraftBinding,
        accessoryLeadingShortcuts: [ChatAccessoryShortcut],
        accessoryShortcuts: [ChatAccessoryShortcut],
        artifactLoader: ChatArtifactLoader,
        theme: ChatTheme
    ) {
        self.draft = draft
        self.accessoryLeadingShortcuts = accessoryLeadingShortcuts
        self.accessoryShortcuts = accessoryShortcuts
        self.artifactLoader = artifactLoader
        self.theme = theme
        guard isViewLoaded else { return }
        renderCurrentState()
    }

    private func startStoreTaskIfNeeded() {
        guard runsStoreTask, storeTask == nil else { return }
        storeTask = Task { [weak self] in
            guard let self else { return }
            await self.store.run()
        }
    }

    private func beginObservation() {
        observationGeneration &+= 1
        observeStore(generation: observationGeneration)
    }

    private func observeStore(generation: Int) {
        let snapshot = withObservationTracking {
            ChatScreenSnapshot(
                rows: store.rows,
                agentState: store.agentState,
                hasMoreHistory: store.hasMoreHistory,
                hasLoadedInitialHistory: store.hasLoadedInitialHistory,
                initialLoadFailed: store.initialLoadFailed,
                historyTruncatedAtHead: store.historyTruncatedAtHead,
                isConnected: store.isConnected,
                lastErrorDescription: store.lastErrorDescription,
                toastsEnabled: toastCenter.isEnabled
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeStore(generation: generation)
            }
        }
        render(snapshot)
    }

    private func renderCurrentState() {
        render(ChatScreenSnapshot(
            rows: store.rows,
            agentState: store.agentState,
            hasMoreHistory: store.hasMoreHistory,
            hasLoadedInitialHistory: store.hasLoadedInitialHistory,
            initialLoadFailed: store.initialLoadFailed,
            historyTruncatedAtHead: store.historyTruncatedAtHead,
            isConnected: store.isConnected,
            lastErrorDescription: store.lastErrorDescription,
            toastsEnabled: toastCenter.isEnabled
        ))
    }

    private func render(_ snapshot: ChatScreenSnapshot) {
        transcriptView.update(configuration: ChatTranscriptTableConfiguration(
            rows: snapshot.rows,
            agentState: snapshot.agentState,
            hasMoreHistory: snapshot.hasMoreHistory,
            hasLoadedInitialHistory: snapshot.hasLoadedInitialHistory,
            initialLoadFailed: snapshot.initialLoadFailed,
            historyTruncatedAtHead: snapshot.historyTruncatedAtHead,
            actions: rowActions(),
            onReachTop: { [weak self] in
                Task { [weak self] in await self?.store.loadOlder() }
            },
            onRetryInitialLoad: { [weak self] in
                Task { [weak self] in await self?.store.retryInitialLoad() }
            },
            theme: theme,
            markdownRenderer: renderer,
            contentCache: contentCache,
            artifactLoader: artifactLoader
        ))
        composerView.update(configuration: composerConfiguration(
            agentState: snapshot.agentState,
            isConnected: snapshot.isConnected
        ))
        keyboardController.showsComposer = snapshot.agentState != .ended
        if providesOwnChrome {
            configureNavigationChrome()
        }
        bridgeError(snapshot.lastErrorDescription, toastsEnabled: snapshot.toastsEnabled)
        announceLatestAgentProseIfNeeded(snapshot.rows)
    }

    private func composerConfiguration(
        agentState: ChatAgentState? = nil,
        isConnected: Bool? = nil
    ) -> ChatComposerNativeConfiguration {
        ChatComposerNativeConfiguration(
            agentState: agentState ?? store.agentState,
            agentKind: store.descriptor.agentKind,
            isTerminal: store.descriptor.kind == .terminal,
            isConnected: isConnected ?? store.isConnected,
            accessoryLeadingShortcuts: accessoryLeadingShortcuts,
            accessoryShortcuts: accessoryShortcuts,
            draft: draft.value,
            setDraft: { [weak self] in self?.draft.value = $0 },
            onSend: { [weak self] text, attachments in
                Task { [weak self] in
                    await self?.store.send(text: text, attachments: attachments)
                }
            },
            onInterrupt: { [weak self] hard in
                Task { [weak self] in await self?.store.interrupt(hard: hard) }
            },
            onOpenTerminal: { [weak self] in self?.onOpenTerminal() }
        )
    }

    private func rowActions() -> ChatRowActions {
        ChatRowActions(
            answerOption: { [weak self] index in
                Task { [weak self] in await self?.store.answer(optionIndex: index) }
            },
            retryPending: { [weak self] id in
                Task { [weak self] in await self?.store.retry(pendingID: id) }
            },
            discardPending: { [weak self] id in self?.store.discard(pendingID: id) },
            openTerminal: { [weak self] in self?.onOpenTerminal() },
            openArtifact: { [weak self] path in self?.openArtifact(path: path) },
            showMessageDetail: { [weak self] message in
                self?.showBlockDetail(.message(id: message.id))
            },
            showTerminalCommandDetail: { [weak self] block in
                self?.showBlockDetail(.terminalCommand(id: block.id))
            },
            showCodeBlockDetail: { [weak self] messageID, segmentIndex in
                self?.showBlockDetail(.codeBlock(
                    messageID: messageID,
                    segmentIndex: segmentIndex
                ))
            },
            notifyCopied: { [weak self] in self?.toastCenter.present(.copied()) }
        )
    }

    private func configureNavigationChrome() {
        let header = ChatSessionHeaderView(
            descriptor: store.descriptor,
            agentState: store.agentState,
            isConnected: store.isConnected
        )
        header.accessibilityIdentifier = "ChatSessionHeader"
        navigationItem.titleView = header
        navigationItem.title = store.descriptor.title ?? store.descriptor.agentKind.displayName
        navigationItem.largeTitleDisplayMode = .never
        let terminal = UIBarButtonItem(
            image: UIImage(systemName: "terminal"),
            style: .plain,
            target: self,
            action: #selector(openTerminalFromToolbar)
        )
        terminal.accessibilityLabel = String(
            localized: "chat.open_terminal.accessibility",
            defaultValue: "Open terminal",
            bundle: .module
        )
        terminal.accessibilityIdentifier = "ChatOpenTerminalButton"
        navigationItem.rightBarButtonItem = terminal
    }

    private func bridgeError(_ error: String?, toastsEnabled: Bool) {
        let key = ErrorBridgeKey(error: error, toastsEnabled: toastsEnabled)
        guard key != lastErrorBridgeKey else { return }
        lastErrorBridgeKey = key
        guard let error else {
            errorBanner.hide()
            return
        }
        if toastsEnabled {
            errorBanner.hide()
            toastCenter.present(.failure(
                error,
                coalescingKey: "chat.conversation.error.\(ObjectIdentifier(store))"
            ))
            store.dismissError()
        } else {
            errorBanner.show(error)
            if UIAccessibility.isVoiceOverRunning {
                AccessibilityNotification.Announcement(error).post()
            }
        }
    }

    private func announceLatestAgentProseIfNeeded(_ rows: [ChatTranscriptRow]) {
        guard let row = rows.last else { return }
        guard row.id != lastAnnouncedRowID else { return }
        lastAnnouncedRowID = row.id
        guard UIAccessibility.isVoiceOverRunning,
              case .message(let snapshot) = row,
              snapshot.message.role == .agent,
              case .prose(let prose) = snapshot.message.kind else { return }
        AccessibilityNotification.Announcement(prose.text).post()
    }

    private func showBlockDetail(_ selection: ChatBlockSelection) {
        guard presentedViewController == nil,
              let detail = blockDetail(for: selection) else { return }
        let terminalAction: (@MainActor () -> Void)?
        if selectionCanOpenTerminal(selection) {
            terminalAction = { [weak self] in self?.onOpenTerminal() }
        } else {
            terminalAction = nil
        }
        let detailController = ChatBlockDetailViewController(
            detail: detail,
            artifactLoader: artifactLoader,
            toastCenter: toastCenter,
            onOpenTerminal: terminalAction
        )
        let navigation = UINavigationController(rootViewController: detailController)
        navigation.modalPresentationStyle = UIModalPresentationStyle.pageSheet
        present(navigation, animated: true)
    }

    private func openArtifact(path: String) {
        let viewer = ChatArtifactViewerController(
            path: path,
            loader: artifactLoader,
            toastCenter: toastCenter,
            onDone: { [weak self] in
                guard let self else { return }
                if let navigationController = self.navigationController,
                   navigationController.topViewController !== self {
                    self.navigationController?.popToViewController(self, animated: true)
                } else {
                    self.dismiss(animated: true)
                }
            }
        )
        if let navigationController {
            navigationController.pushViewController(viewer, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: viewer)
            navigation.modalPresentationStyle = UIModalPresentationStyle.pageSheet
            present(navigation, animated: true)
        }
    }

    private func blockDetail(for selection: ChatBlockSelection) -> ChatBlockDetail? {
        switch selection {
        case .message(let id):
            guard let message = currentMessage(id: id) else { return nil }
            return detailBuilder.detail(message: message)
        case .terminalCommand(let id):
            guard let block = currentTerminalBlock(id: id) else { return nil }
            return detailBuilder.detail(block: block)
        case .codeBlock(let messageID, let segmentIndex):
            guard let message = currentMessage(id: messageID),
                  case .prose(let prose) = message.kind,
                  let segment = contentCache
                      .proseSegments(messageID: messageID, text: prose.text)
                      .first(where: { $0.index == segmentIndex }),
                  case .code(let language) = segment.kind else { return nil }
            return detailBuilder.codeBlock(
                id: "code-\(messageID)-\(segmentIndex)",
                code: segment.content,
                language: language
            )
        }
    }

    private func currentMessage(id: String) -> ChatMessage? {
        for row in store.rows {
            if case .message(let snapshot) = row, snapshot.message.id == id {
                return snapshot.message
            }
        }
        return nil
    }

    private func currentTerminalBlock(id: Int) -> TerminalCommandBlock? {
        for row in store.rows {
            if case .terminalCommand(let block) = row, block.id == id {
                return block
            }
        }
        return nil
    }

    private func selectionCanOpenTerminal(_ selection: ChatBlockSelection) -> Bool {
        switch selection {
        case .terminalCommand:
            true
        case .message(let id):
            if let message = currentMessage(id: id), case .terminal = message.kind {
                true
            } else {
                false
            }
        case .codeBlock:
            false
        }
    }

    @objc private func openTerminalFromToolbar() {
        onOpenTerminal()
    }
}

private struct ChatScreenSnapshot {
    let rows: [ChatTranscriptRow]
    let agentState: ChatAgentState
    let hasMoreHistory: Bool
    let hasLoadedInitialHistory: Bool
    let initialLoadFailed: Bool
    let historyTruncatedAtHead: Bool
    let isConnected: Bool
    let lastErrorDescription: String?
    let toastsEnabled: Bool
}

private struct ErrorBridgeKey: Equatable {
    let error: String?
    let toastsEnabled: Bool
}

@MainActor
private final class ChatErrorBannerView: UIControl {
    var onDismiss: @MainActor () -> Void = {}

    private let label = UILabel()
    private let clock: any Clock<Duration> = ContinuousClock()
    private var autoDismissTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemRed.withAlphaComponent(0.92)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "ChatErrorBanner"
        isAccessibilityElement = true
        accessibilityTraits = .button
        isHidden = true
        alpha = 0

        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .white
        label.numberOfLines = 2
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        addTarget(self, action: #selector(dismissPressed), for: .primaryActionTriggered)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(dismissPressed))
        swipe.direction = .up
        addGestureRecognizer(swipe)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ message: String) {
        label.text = message
        accessibilityLabel = message
        isHidden = false
        transform = CGAffineTransform(translationX: 0, y: -8)
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
            animations: {
                self.alpha = 1
                self.transform = .identity
            }
        )
        scheduleAutoDismiss()
    }

    func hide() {
        cancelAutoDismiss()
        guard !isHidden else { return }
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2,
            animations: {
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: 0, y: -8)
            },
            completion: { _ in self.isHidden = true }
        )
    }

    func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        autoDismissTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.onDismiss()
        }
    }

    @objc private func dismissPressed() {
        onDismiss()
    }
}
#endif
