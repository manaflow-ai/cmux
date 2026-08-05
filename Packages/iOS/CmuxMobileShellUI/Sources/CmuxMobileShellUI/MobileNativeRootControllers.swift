#if os(iOS)
import CMUXMobileCore
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileChanges
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileToast
import UIKit

@MainActor
final class MobileOnboardingViewController: UIViewController {
    private let coordinator: MobileRootCoordinator
    private let analytics: any AnalyticsEmitting
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let imageView = UIImageView()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private var welcomePage = 0

    init(coordinator: MobileRootCoordinator, analytics: any AnalyticsEmitting) {
        self.coordinator = coordinator
        self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground

        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .label
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 66, weight: .regular)

        titleLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
            for: .systemFont(ofSize: 34, weight: .bold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0
        bodyLabel.textAlignment = .center

        var primaryConfiguration = UIButton.Configuration.filled()
        primaryConfiguration.cornerStyle = .capsule
        primaryConfiguration.buttonSize = .large
        primaryButton.configuration = primaryConfiguration
        primaryButton.addAction(UIAction { [weak self] _ in self?.performPrimaryAction() }, for: .touchUpInside)
        primaryButton.accessibilityIdentifier = "MobileOnboardingPrimaryButton"

        var secondaryConfiguration = UIButton.Configuration.plain()
        secondaryConfiguration.buttonSize = .large
        secondaryButton.configuration = secondaryConfiguration
        secondaryButton.addAction(UIAction { [weak self] _ in self?.skip() }, for: .touchUpInside)
        secondaryButton.accessibilityIdentifier = "MobileOnboardingSkipButton"

        let stack = UIStackView(arrangedSubviews: [
            imageView,
            titleLabel,
            bodyLabel,
            primaryButton,
            secondaryButton,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.setCustomSpacing(34, after: bodyLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.heightAnchor.constraint(equalToConstant: 110),
            stack.leadingAnchor.constraint(equalTo: root.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: root.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        view = root
        update()
    }

    func update() {
        guard isViewLoaded else { return }
        if coordinator.onboardingStore.progress == .connect {
            if coordinator.store.connectionState == .connected {
                coordinator.completeOnboarding()
                return
            }
            imageView.image = UIImage(systemName: "macbook.and.iphone")
            titleLabel.text = L10n.string(
                "mobile.onboarding.connection.title",
                defaultValue: "Connect your Mac"
            )
            bodyLabel.text = coordinator.store.isReconnectingStoredMac
                ? L10n.string(
                    "mobile.onboarding.connection.searching",
                    defaultValue: "Looking for a signed-in Mac…"
                )
                : L10n.string(
                    "mobile.onboarding.connection.message",
                    defaultValue: "Open cmux on your Mac, then connect automatically or scan its pairing code."
                )
            primaryButton.configuration?.title = coordinator.store.isReconnectingStoredMac
                ? L10n.string("mobile.common.working", defaultValue: "Connecting…")
                : L10n.string("mobile.onboarding.connection.retry", defaultValue: "Try Again")
            primaryButton.isEnabled = !coordinator.store.isReconnectingStoredMac
            secondaryButton.configuration?.title = L10n.string(
                "mobile.onboarding.connection.scan",
                defaultValue: "Scan Pairing Code"
            )
            return
        }

        let pages: [(image: String, title: String, body: String)] = [
            (
                "rectangle.3.group.bubble.left",
                L10n.string("mobile.onboarding.agents.title", defaultValue: "Your agents, from anywhere"),
                L10n.string(
                    "mobile.onboarding.agents.message",
                    defaultValue: "Follow every workspace and answer your coding agents from your phone."
                )
            ),
            (
                "bell.badge",
                L10n.string("mobile.onboarding.notifications.title", defaultValue: "Know when they need you"),
                L10n.string(
                    "mobile.onboarding.notifications.message",
                    defaultValue: "cmux sends focused notifications when an agent finishes or needs input."
                )
            ),
        ]
        let page = pages[min(welcomePage, pages.count - 1)]
        imageView.image = UIImage(systemName: page.image)
        titleLabel.text = page.title
        bodyLabel.text = page.body
        primaryButton.configuration?.title = welcomePage == pages.count - 1
            ? L10n.string("mobile.onboarding.getStarted", defaultValue: "Get Started")
            : L10n.string("mobile.common.continue", defaultValue: "Continue")
        primaryButton.isEnabled = true
        secondaryButton.configuration?.title = L10n.string("mobile.onboarding.skip", defaultValue: "Skip")
        view.accessibilityIdentifier = "MobileOnboardingScene-\(welcomePage)"
    }

    private func performPrimaryAction() {
        if coordinator.onboardingStore.progress == .connect {
            analytics.capture("ios_onboarding_connection_retry", [:])
            coordinator.retryAutomaticConnection()
        } else if welcomePage == 0 {
            welcomePage = 1
            update()
        } else {
            analytics.capture("ios_onboarding_tour_completed", [:])
            coordinator.markOnboardingReadyToConnect()
        }
    }

    private func skip() {
        if coordinator.onboardingStore.progress == .connect {
            coordinator.presentPairingScanner(entry: .onboardingFallback)
        } else {
            analytics.capture("ios_onboarding_skipped", [:])
            coordinator.completeOnboarding()
        }
    }
}

@MainActor
final class MobileDisconnectedViewController: UIViewController {
    private let coordinator: MobileRootCoordinator
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    init(coordinator: MobileRootCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground

        let image = UIImageView(image: UIImage(systemName: "macbook.and.iphone"))
        image.tintColor = .secondaryLabel
        image.contentMode = .scaleAspectFit
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 58)

        titleLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(
            for: .systemFont(ofSize: 28, weight: .bold)
        )
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var primary = UIButton.Configuration.filled()
        primary.cornerStyle = .capsule
        primary.buttonSize = .large
        retryButton.configuration = primary
        retryButton.addAction(UIAction { [weak self] _ in self?.coordinator.retryAutomaticConnection() }, for: .touchUpInside)
        retryButton.accessibilityIdentifier = "MobileRetryConnectionButton"

        let addButton = UIButton(type: .system)
        var add = UIButton.Configuration.bordered()
        add.cornerStyle = .capsule
        add.buttonSize = .large
        add.title = L10n.string("mobile.addDevice.title", defaultValue: "Add Computer")
        add.image = UIImage(systemName: "plus")
        add.imagePadding = 7
        addButton.configuration = add
        addButton.addAction(UIAction { [weak self] _ in self?.coordinator.presentAddComputer() }, for: .touchUpInside)
        addButton.accessibilityIdentifier = "MobileAddDeviceButton"

        let signOut = UIButton(type: .system)
        signOut.configuration = .plain()
        signOut.configuration?.title = L10n.string("mobile.settings.signOut", defaultValue: "Sign Out")
        signOut.addAction(UIAction { [weak self] _ in self?.coordinator.signOut() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [image, titleLabel, messageLabel, retryButton, addButton, signOut])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.setCustomSpacing(28, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            image.heightAnchor.constraint(equalToConstant: 100),
            stack.leadingAnchor.constraint(equalTo: root.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: root.safeAreaLayoutGuide.centerYAnchor),
        ])
        view = root
        view.accessibilityIdentifier = "MobileDisconnectedWorkspaceShell"
        update()
    }

    func update() {
        guard isViewLoaded else { return }
        titleLabel.text = coordinator.store.hasKnownPairedMac
            ? L10n.string("mobile.disconnected.title", defaultValue: "Mac unavailable")
            : L10n.string("mobile.disconnected.noComputerTitle", defaultValue: "Connect a computer")
        messageLabel.text = coordinator.store.connectionError
            ?? coordinator.store.connectionErrorGuidance
            ?? L10n.string(
                "mobile.disconnected.message",
                defaultValue: "Make sure cmux is open on your Mac, then reconnect."
            )
        retryButton.configuration?.title = coordinator.store.isReconnectingStoredMac
            ? L10n.string("mobile.common.working", defaultValue: "Connecting…")
            : L10n.string("mobile.disconnected.retry", defaultValue: "Reconnect")
        retryButton.isEnabled = !coordinator.store.isReconnectingStoredMac
    }
}

@MainActor
final class MobileWorkspaceShellViewController: UIViewController {
    private let store: CMUXMobileShellStore
    private let coordinator: MobileRootCoordinator
    private let browserStore: BrowserSurfaceStore
    private let browserStreamStore: BrowserStreamStore
    private let shellNavigationController: UINavigationController
    private let listController: MobileWorkspaceListViewController
    private let notificationProjection = NotificationFeedProjection()
    private lazy var notificationController = makeNotificationController()
    private lazy var notificationNavigationController = UINavigationController(
        rootViewController: notificationController
    )
    private lazy var shellTabController: UITabBarController = {
        let controller = UITabBarController()
        controller.viewControllers = [shellNavigationController, notificationNavigationController]
        return controller
    }()
    private var notificationOpenTask: Task<Void, Never>?

    init(
        store: CMUXMobileShellStore,
        coordinator: MobileRootCoordinator,
        browserStore: BrowserSurfaceStore,
        browserStreamStore: BrowserStreamStore,
        isRestoringStoredMac: Bool
    ) {
        self.store = store
        self.coordinator = coordinator
        self.browserStore = browserStore
        self.browserStreamStore = browserStreamStore
        self.listController = MobileWorkspaceListViewController(store: store, coordinator: coordinator)
        self.shellNavigationController = UINavigationController(rootViewController: listController)
        super.init(nibName: nil, bundle: nil)
        listController.openWorkspace = { [weak self] workspace in
            self?.open(workspace)
        }
        update(isRestoringStoredMac: isRestoringStoredMac)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { notificationOpenTask?.cancel() }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .systemBackground
        addChild(shellTabController)
        shellTabController.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(shellTabController.view)
        NSLayoutConstraint.activate([
            shellTabController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shellTabController.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shellTabController.view.topAnchor.constraint(equalTo: root.topAnchor),
            shellTabController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        shellTabController.didMove(toParent: self)
        view = root
    }

    func update(isRestoringStoredMac: Bool) {
        listController.update(isRestoringStoredMac: isRestoringStoredMac)
        notificationProjection.update(items: store.notificationFeedItems)
        notificationController.update(status: store.notificationFeedStatus)
        notificationNavigationController.tabBarItem.badgeValue = store.notificationFeedUnreadCount == 0
            ? nil
            : store.notificationFeedUnreadCount.formatted()
        if let detail = shellNavigationController.topViewController as? MobileWorkspaceDetailViewController {
            detail.update()
            if store.selectedWorkspaceID == nil {
                shellNavigationController.popToRootViewController(animated: true)
            }
        }
    }

    private func open(_ workspace: MobileWorkspacePreview) {
        shellTabController.selectedIndex = 0
        let detail = MobileWorkspaceDetailViewController(
            store: store,
            workspaceID: workspace.id,
            browserStore: browserStore,
            browserStreamStore: browserStreamStore,
            displaySettings: coordinator.displaySettings,
            toastCenter: coordinator.toastCenter
        )
        shellNavigationController.pushViewController(detail, animated: true)
        Task { [store] in await store.openWorkspace(workspace.id) }
    }

    private func makeNotificationController() -> NotificationFeedViewController {
        let controller = NotificationFeedViewController(
            status: store.notificationFeedStatus,
            projection: notificationProjection,
            refreshesOnAppear: true,
            actions: NotificationFeedActions(
                open: { [weak self] item in self?.openNotification(item) },
                markRead: { [weak store = store] item in
                    Task { await store?.markNotificationFeedItemRead(item) }
                },
                markUnread: { [weak store = store] item in
                    Task { await store?.markNotificationFeedItemUnread(item) }
                },
                markAllRead: { [weak store = store] in
                    Task { await store?.markAllNotificationFeedItemsRead() }
                },
                refresh: { [weak store = store] in
                    guard let store else { return }
                    await store.refreshNotificationFeed()
                }
            )
        )
        controller.tabBarItem = UITabBarItem(
            title: L10n.string("mobile.notificationFeed.title", defaultValue: "Notifications"),
            image: UIImage(systemName: "bell"),
            selectedImage: UIImage(systemName: "bell.fill")
        )
        return controller
    }

    private func openNotification(_ item: MobileNotificationFeedItem) {
        notificationOpenTask?.cancel()
        notificationOpenTask = Task { [weak self] in
            guard let self else { return }
            await store.openNotificationFeedItem(item)
            guard !Task.isCancelled else { return }
            shellTabController.selectedIndex = 0
            if let selectedID = store.selectedWorkspaceID,
               let workspace = store.workspaces.first(where: { $0.id == selectedID }) {
                open(workspace)
            }
        }
    }
}

@MainActor
private final class MobileWorkspaceListViewController: UITableViewController {
    private let store: CMUXMobileShellStore
    private let coordinator: MobileRootCoordinator
    private var workspaces: [MobileWorkspacePreview] = []
    private var isRestoringStoredMac = false
    var openWorkspace: (@MainActor (MobileWorkspacePreview) -> Void)?

    init(store: CMUXMobileShellStore, coordinator: MobileRootCoordinator) {
        self.store = store
        self.coordinator = coordinator
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.workspaces.title", defaultValue: "Workspaces")
        tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: "rectangle.3.group"),
            selectedImage: UIImage(systemName: "rectangle.3.group.fill")
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "MobileWorkspaceList"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "workspace")
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                menu: creationMenu
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "gearshape"),
                primaryAction: UIAction(
                    title: L10n.string("mobile.workspaces.settings", defaultValue: "Settings")
                ) { [weak self] _ in self?.presentSettings() }
            ),
        ]
        update(isRestoringStoredMac: isRestoringStoredMac)
    }

    private var creationMenu: UIMenu {
        var actions: [UIMenuElement] = []
        if coordinator.displaySettings.taskComposerEnabled {
            actions.append(UIAction(
                title: L10n.string("mobile.taskComposer.title", defaultValue: "New Task"),
                image: UIImage(systemName: "sparkles")
            ) { [weak self] _ in self?.presentTaskComposer() })
        }
        actions.append(UIAction(
            title: L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
            image: UIImage(systemName: "plus.square.on.square")
        ) { [weak self] _ in self?.store.createWorkspace() })
        actions.append(UIAction(
            title: L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"),
            image: UIImage(systemName: "desktopcomputer.badge.plus")
        ) { [weak self] _ in self?.coordinator.presentAddComputer() })
        return UIMenu(children: actions)
    }

    func update(isRestoringStoredMac: Bool) {
        self.isRestoringStoredMac = isRestoringStoredMac
        workspaces = store.workspaces
        guard isViewLoaded else { return }
        navigationItem.rightBarButtonItems?.first?.menu = creationMenu
        tableView.reloadData()
        updateBackground()
    }

    @objc private func refresh() {
        Task { [weak self, store] in
            await store.refreshWorkspaces()
            self?.tableView.refreshControl?.endRefreshing()
        }
    }

    private func presentSettings() {
        let controller = MobileSettingsViewController(coordinator: coordinator)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }

    private func presentTaskComposer() {
        let controller = MobileTaskComposerViewController(store: store)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    private func updateBackground() {
        guard workspaces.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.text = isRestoringStoredMac
            ? L10n.string("mobile.workspaces.restoring", defaultValue: "Restoring your Mac connection…")
            : L10n.string("mobile.workspaces.empty", defaultValue: "No workspaces are available.")
        tableView.backgroundView = label
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        workspaces.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let workspace = workspaces[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "workspace", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = workspace.name
        content.secondaryText = workspace.previewText
            ?? workspace.customDescription
            ?? workspace.macDisplayName
        content.image = UIImage(systemName: workspace.hasUnread ? "circle.fill" : "terminal")
        content.imageProperties.tintColor = workspace.hasUnread ? .systemBlue : .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "MobileWorkspaceRow-\(workspace.id.rawValue)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openWorkspace?(workspaces[indexPath.row])
    }
}

@MainActor
private final class MobileWorkspaceDetailViewController: UIViewController {
    private let store: CMUXMobileShellStore
    private let workspaceID: MobileWorkspacePreview.ID
    private let browserStore: BrowserSurfaceStore
    private let browserStreamStore: BrowserStreamStore
    private let displaySettings: MobileDisplaySettings
    private let toastCenter: ToastCenter
    private let contentView = UIView()
    private let placeholderLabel = UILabel()
    private let statusLabel = PaddingLabel()
    private var surfaceController: GhosttySurfaceController?
    private var surfaceID: String?
    private var chatSessions: [ChatSessionDescriptor] = []
    private var chatConversation: ChatConversationStore?
    private var chatController: ChatViewController?
    private var browserController: MobileBrowserPane?
    private var browserStreamController: BrowserStreamPane?
    private var browserStreamPanelID: String?
    private var chatDraft = ""
    private var chatSessionTask: Task<Void, Never>?
    private var chatWorkspaceID: String?
    private var isShowingChat = false
    private let terminalArtifactThumbnailCache = ChatArtifactThumbnailCache()

    init(
        store: CMUXMobileShellStore,
        workspaceID: MobileWorkspacePreview.ID,
        browserStore: BrowserSurfaceStore,
        browserStreamStore: BrowserStreamStore,
        displaySettings: MobileDisplaySettings,
        toastCenter: ToastCenter
    ) {
        self.store = store
        self.workspaceID = workspaceID
        self.browserStore = browserStore
        self.browserStreamStore = browserStreamStore
        self.displaySettings = displaySettings
        self.toastCenter = toastCenter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { chatSessionTask?.cancel() }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = store.activeTerminalTheme.terminalBackgroundUIColor
        root.accessibilityIdentifier = "MobileWorkspaceDetail"

        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: root.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 0
        contentView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.layer.cornerRadius = 10
        statusLabel.layer.masksToBounds = true
        statusLabel.isHidden = true
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            statusLabel.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])
        view = root
        update()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        Task { [weak self, store] in
            await store.refreshMobileBrowserPanels(workspaceID: workspace.rpcWorkspaceID.rawValue)
            self?.update()
        }
    }

    func update() {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            title = L10n.string("mobile.workspace.title", defaultValue: "Workspace")
            placeholderLabel.text = L10n.string("mobile.workspace.unavailable", defaultValue: "This workspace is no longer available.")
            placeholderLabel.isHidden = false
            removeSurface()
            return
        }
        title = workspace.name
        guard isViewLoaded else { return }
        startChatSessionObservationIfNeeded(workspace: workspace)
        view.backgroundColor = store.activeTerminalTheme.terminalBackgroundUIColor
        updateStatus(workspace.macConnectionStatus ?? store.workspaceListConnectionStatus)
        let terminal = workspace.terminals.first { $0.id == store.selectedTerminalID }
            ?? workspace.terminals.first
        if let terminal {
            placeholderLabel.isHidden = true
            installOrUpdateSurface(workspace: workspace, terminal: terminal)
        } else {
            placeholderLabel.text = L10n.string("mobile.workspace.noTerminals", defaultValue: "No terminals are available.")
            removeSurface()
            placeholderLabel.isHidden = browserStore.activeBrowser(for: workspace.id.rawValue) != nil
                || browserStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue) != nil
        }
        updatePresentedSurface(workspace: workspace, selectedTerminal: terminal)
        configureToolbar(workspace: workspace, selectedTerminal: terminal)
    }

    private func installOrUpdateSurface(
        workspace: MobileWorkspacePreview,
        terminal: MobileTerminalPreview
    ) {
        let terminalID = terminal.id.rawValue
        if surfaceID != terminalID {
            removeSurface()
            let controller = GhosttySurfaceController(
                workspaceID: workspace.id.rawValue,
                surfaceID: terminalID,
                store: store,
                fontSize: MobileTerminalFontPreference.defaultSize,
                autoFocusOnWindowAttach: store.shouldAutoFocusTerminalSurface(terminalID)
                    && !store.isComposerPresented,
                isComposerActive: store.isComposerPresented,
                terminalTheme: store.activeTerminalTheme,
                terminalConfigTheme: store.activeTerminalConfigTheme,
                configThemeGeneration: store.terminalConfigThemeGeneration,
                artifactFilesEnabled: store.supportsTerminalArtifacts,
                terminalFolderTapEnabled: displaySettings.terminalFolderTapEnabled,
                terminalFilesChipEnabled: displaySettings.terminalFilesChipEnabled,
                showMissingFiles: displaySettings.showMissingFiles,
                sessionArtifactCountEnabled: store.supportsChatArtifactGallery,
                onArtifactFilesRequested: { [weak self] _ in
                    self?.presentArtifactGallery(workspaceID: workspace.id.rawValue, surfaceID: terminalID)
                },
                onArtifactPathTapped: { [weak self] path in
                    self?.presentArtifact(
                        path: path,
                        workspace: workspace,
                        terminal: terminal
                    )
                }
            )
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.insertSubview(controller.view, at: 0)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
            controller.didMove(toParent: self)
            surfaceController = controller
            surfaceID = terminalID
            store.consumeTerminalAutoFocusSuppression(for: terminalID)
        } else {
            surfaceController?.update(
                autoFocusOnWindowAttach: store.shouldAutoFocusTerminalSurface(terminalID)
                    && !store.isComposerPresented,
                isComposerActive: store.isComposerPresented,
                terminalTheme: store.activeTerminalTheme,
                terminalConfigTheme: store.activeTerminalConfigTheme,
                configThemeGeneration: store.terminalConfigThemeGeneration,
                artifactFilesEnabled: store.supportsTerminalArtifacts,
                terminalFolderTapEnabled: displaySettings.terminalFolderTapEnabled,
                terminalFilesChipEnabled: displaySettings.terminalFilesChipEnabled,
                showMissingFiles: displaySettings.showMissingFiles,
                sessionArtifactCountEnabled: store.supportsChatArtifactGallery,
                visibleArtifactCount: 0
            )
        }
    }

    private func removeSurface() {
        guard let surfaceController else { return }
        surfaceController.willMove(toParent: nil)
        surfaceController.view.removeFromSuperview()
        surfaceController.removeFromParent()
        self.surfaceController = nil
        surfaceID = nil
    }

    private func startChatSessionObservationIfNeeded(workspace: MobileWorkspacePreview) {
        let rawWorkspaceID = workspace.id.rawValue
        guard chatWorkspaceID != rawWorkspaceID else { return }
        chatSessionTask?.cancel()
        chatWorkspaceID = rawWorkspaceID
        chatSessions = store.cachedChatSessions(workspaceID: rawWorkspaceID)
        chatSessionTask = Task { [weak self, weak store] in
            guard let self, let store, let source = store.makeChatEventSource() else { return }
            var reducer = ChatSessionListReducer(workspaceID: rawWorkspaceID)
            let stream = await source.sessionEvents()
            if let initial = try? await source.sessions(workspaceID: rawWorkspaceID) {
                guard !Task.isCancelled else { return }
                chatSessions = initial
                store.rememberChatSessions(initial, workspaceID: rawWorkspaceID)
                update()
            }
            for await frame in stream {
                guard !Task.isCancelled else { return }
                let next = reducer.applying(frame, to: chatSessions)
                guard next != chatSessions else { continue }
                chatSessions = next
                store.rememberChatSessions(next, workspaceID: rawWorkspaceID)
                update()
            }
        }
    }

    private func chatSession(for terminal: MobileTerminalPreview?) -> ChatSessionDescriptor? {
        guard let terminal else { return nil }
        return chatSessions.first { $0.terminalID == terminal.id.rawValue }
    }

    private func updatePresentedSurface(
        workspace: MobileWorkspacePreview,
        selectedTerminal: MobileTerminalPreview?
    ) {
        if isShowingChat,
           let session = chatSession(for: selectedTerminal),
           let source = store.makeChatEventSource() {
            removeBrowserController()
            removeBrowserStreamController(stopping: false)
            surfaceController?.view.isHidden = true
            installOrUpdateChat(session: session, source: source)
            return
        }
        if isShowingChat { isShowingChat = false }
        removeChatController()

        if let browser = browserStore.activeBrowser(for: workspace.id.rawValue) {
            removeBrowserStreamController(stopping: false)
            surfaceController?.view.isHidden = true
            installOrUpdateBrowser(browser, workspace: workspace)
            placeholderLabel.isHidden = true
            return
        }
        removeBrowserController()

        if let stream = browserStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue) {
            surfaceController?.view.isHidden = true
            installOrUpdateBrowserStream(stream, workspace: workspace)
            placeholderLabel.isHidden = true
            return
        }
        removeBrowserStreamController(stopping: false)
        surfaceController?.view.isHidden = false
    }

    private func installOrUpdateChat(session: ChatSessionDescriptor, source: MobileChatEventSource) {
        if chatConversation?.descriptor.id == session.id, chatController != nil { return }
        removeChatController()
        let conversation = ChatConversationStore(
            descriptor: session,
            source: source,
            sourceIdentity: store.agentChatEventSourceIdentity
        )
        let controller = ChatViewController(
            store: conversation,
            draft: ChatDraftBinding(
                get: { [weak self] in self?.chatDraft ?? "" },
                set: { [weak self] in self?.chatDraft = $0 }
            ),
            artifactLoader: store.supportsChatArtifacts
                ? ChatArtifactLoader(source: source, sessionID: session.id)
                : .unsupported(),
            toastCenter: toastCenter,
            providesOwnChrome: false,
            runsStoreTask: true,
            onOpenTerminal: { [weak self] in self?.showTerminal() }
        )
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        chatConversation = conversation
        chatController = controller
    }

    private func installOrUpdateBrowser(
        _ browser: BrowserSurfaceState,
        workspace: MobileWorkspacePreview
    ) {
        if let browserController {
            browserController.update(onClose: { [weak self] in
                self?.closeBrowser(workspace: workspace)
            })
            return
        }
        let controller = MobileBrowserPane(state: browser) { [weak self] in
            self?.closeBrowser(workspace: workspace)
        }
        installSecondaryController(controller)
        browserController = controller
    }

    private func closeBrowser(workspace: MobileWorkspacePreview) {
        browserStore.closeBrowser(for: workspace.id.rawValue)
        update()
    }

    private func installOrUpdateBrowserStream(
        _ stream: BrowserStreamSurfaceState,
        workspace: MobileWorkspacePreview
    ) {
        if browserStreamPanelID == stream.id, let browserStreamController {
            browserStreamController.update(reconnect: { [weak store] in
                Task { await store?.reconnectOrRefresh() }
            })
            return
        }
        removeBrowserStreamController(stopping: false)
        let controller = BrowserStreamPane(
            state: stream,
            actions: BrowserStreamSurfaceActions(
                pointer: { [weak store] event in await store?.sendMobileBrowserPointer(event) },
                scroll: { [weak store] event in await store?.sendMobileBrowserScroll(event) },
                key: { [weak store] event in await store?.sendMobileBrowserKey(event) },
                text: { [weak store] event in await store?.sendMobileBrowserText(event) },
                viewport: { [weak store, weak browserStreamStore] parameters in
                    await browserStreamStore?.reportBrowserStreamViewport(parameters)
                    await store?.updateMobileBrowserViewport(parameters)
                },
                navigate: { [weak store] panelID, url in
                    await store?.navigateMobileBrowser(panelID: panelID, url: url)
                },
                back: { [weak store] panelID in await store?.backMobileBrowser(panelID: panelID) },
                forward: { [weak store] panelID in await store?.forwardMobileBrowser(panelID: panelID) },
                reload: { [weak store] panelID in await store?.reloadMobileBrowser(panelID: panelID) },
                respondToDialog: { [weak store] response in
                    await store?.respondToMobileBrowserDialog(response)
                }
            ),
            reconnect: { [weak store] in Task { await store?.reconnectOrRefresh() } }
        )
        installSecondaryController(controller)
        browserStreamController = controller
        browserStreamPanelID = stream.id
    }

    private func installSecondaryController(_ controller: UIViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func removeBrowserController() {
        guard let browserController else { return }
        browserController.willMove(toParent: nil)
        browserController.view.removeFromSuperview()
        browserController.removeFromParent()
        self.browserController = nil
    }

    private func removeBrowserStreamController(stopping: Bool) {
        guard let browserStreamController else { return }
        browserStreamController.willMove(toParent: nil)
        browserStreamController.view.removeFromSuperview()
        browserStreamController.removeFromParent()
        self.browserStreamController = nil
        let panelID = browserStreamPanelID
        browserStreamPanelID = nil
        if stopping, let panelID {
            Task { [weak store] in await store?.stopMobileBrowserStream(panelID: panelID) }
        }
    }

    private func removeChatController() {
        guard let chatController else {
            chatConversation = nil
            return
        }
        chatController.willMove(toParent: nil)
        chatController.view.removeFromSuperview()
        chatController.removeFromParent()
        self.chatController = nil
        chatConversation = nil
    }

    private func toggleChat(workspace: MobileWorkspacePreview, terminal: MobileTerminalPreview) {
        isShowingChat.toggle()
        updatePresentedSurface(workspace: workspace, selectedTerminal: terminal)
        configureToolbar(workspace: workspace, selectedTerminal: terminal)
    }

    private func showTerminal() {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              let terminal = workspace.terminals.first(where: { $0.id == store.selectedTerminalID })
                ?? workspace.terminals.first else { return }
        isShowingChat = false
        updatePresentedSurface(workspace: workspace, selectedTerminal: terminal)
        configureToolbar(workspace: workspace, selectedTerminal: terminal)
    }

    private func updateStatus(_ status: MobileMacConnectionStatus) {
        guard status != .connected else {
            statusLabel.isHidden = true
            return
        }
        statusLabel.text = status.label
        statusLabel.textColor = .label
        statusLabel.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.92)
        statusLabel.isHidden = false
    }

    private func configureToolbar(
        workspace: MobileWorkspacePreview,
        selectedTerminal: MobileTerminalPreview?
    ) {
        let terminalActions = workspace.terminals.map { terminal in
            UIAction(
                title: terminal.name,
                image: UIImage(systemName: "terminal"),
                state: terminal.id == selectedTerminal?.id ? .on : .off
            ) { [weak self] _ in
                self?.selectTerminal(terminal.id, workspace: workspace)
            }
        }
        var children: [UIMenuElement] = [
            UIMenu(
                title: L10n.string("mobile.workspace.terminals", defaultValue: "Terminals"),
                options: .displayInline,
                children: terminalActions
            ),
            UIAction(
                title: L10n.string("mobile.workspace.newTerminal", defaultValue: "New Terminal"),
                image: UIImage(systemName: "plus.rectangle")
            ) { [weak self] _ in self?.createTerminal(in: workspace) },
            UIAction(
                title: L10n.string("mobile.workspace.newBrowser", defaultValue: "New Browser"),
                image: UIImage(systemName: "globe"),
                state: browserStore.hasBrowser(for: workspace.id.rawValue) ? .on : .off
            ) { [weak self] _ in self?.openBrowser(in: workspace) },
            UIAction(
                title: L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak self] _ in self?.store.createWorkspace() },
        ]
        if store.supportsBrowserStream {
            let activePanelID = browserStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue)?.id
            let streamActions = browserStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue).map { panel in
                let row = BrowserStreamPickerRow(panel)
                return UIAction(
                    title: row.label,
                    image: UIImage(systemName: "macwindow"),
                    state: row.id == activePanelID ? .on : .off
                ) { [weak self] _ in self?.selectBrowserStream(row.id, workspace: workspace) }
            }
            if !streamActions.isEmpty {
                children.append(UIMenu(
                    title: L10n.string("mobile.workspace.macBrowsers", defaultValue: "Mac Browsers"),
                    options: .displayInline,
                    children: streamActions
                ))
            }
        }
        if workspace.actionCapabilities.supportsWorkspaceActions {
            children.append(UIAction(
                title: L10n.string("mobile.workspace.rename", defaultValue: "Rename Workspace"),
                image: UIImage(systemName: "pencil")
            ) { [weak self] _ in self?.presentRename(workspace) })
        }
        if workspace.actionCapabilities.supportsReadStateActions {
            children.append(UIAction(
                title: workspace.hasUnread
                    ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
                    : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread"),
                image: UIImage(systemName: workspace.hasUnread ? "envelope.open" : "envelope.badge")
            ) { [weak self] _ in
                guard let self else { return }
                Task { _ = await store.setWorkspaceUnread(id: workspace.id, !workspace.hasUnread) }
            })
        }
        if workspace.actionCapabilities.supportsCloseActions {
            children.append(UIAction(
                title: L10n.string("mobile.workspace.delete", defaultValue: "Delete Workspace"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.confirmClose(workspace) })
        }
        var toolbarItems: [UIBarButtonItem] = []
        if store.workspaceChangesCapable,
           (workspace.macConnectionStatus ?? store.workspaceListConnectionStatus) == .connected {
            let changes = UIBarButtonItem(
                image: UIImage(systemName: "doc.text.magnifyingglass"),
                primaryAction: UIAction(
                    title: L10n.string("workspace.changes.title", defaultValue: "Changes")
                ) { [weak self] _ in self?.presentWorkspaceChanges(workspace) }
            )
            changes.accessibilityIdentifier = "MobileWorkspaceChangesButton"
            toolbarItems.append(changes)
        }
        if let selectedTerminal, chatSession(for: selectedTerminal) != nil {
            let chat = UIBarButtonItem(
                image: UIImage(systemName: isShowingChat
                    ? "bubble.left.and.bubble.right.fill"
                    : "bubble.left.and.bubble.right"),
                primaryAction: UIAction(
                    title: L10n.string("mobile.workspace.agentChat", defaultValue: "Agent Chat")
                ) { [weak self] _ in
                    self?.toggleChat(workspace: workspace, terminal: selectedTerminal)
                }
            )
            chat.accessibilityIdentifier = "MobileWorkspaceAgentChatButton"
            toolbarItems.append(chat)
        }
        toolbarItems.append(
            UIBarButtonItem(
                image: UIImage(systemName: "rectangle.stack"),
                menu: UIMenu(children: children)
            )
        )
        navigationItem.rightBarButtonItems = toolbarItems
    }

    private func presentWorkspaceChanges(_ workspace: MobileWorkspacePreview) {
        let controller = MobileWorkspaceChangesViewController(
            store: store,
            workspaceID: workspace.rpcWorkspaceID.rawValue,
            workspaceTitle: workspace.name
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
        store.dismissWorkspaceChangesHint(workspaceID: workspace.rpcWorkspaceID.rawValue)
    }

    private func selectTerminal(
        _ terminalID: MobileTerminalPreview.ID,
        workspace: MobileWorkspacePreview
    ) {
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream(in: workspace)
        store.selectTerminalFromChrome(terminalID)
        update()
    }

    private func createTerminal(in workspace: MobileWorkspacePreview) {
        browserStore.closeBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream(in: workspace)
        store.createTerminal(in: workspace.id)
        update()
    }

    private func openBrowser(in workspace: MobileWorkspacePreview) {
        _ = browserStore.openBrowser(for: workspace.id.rawValue)
        stopActiveBrowserStream(in: workspace)
        update()
    }

    private func selectBrowserStream(_ panelID: String, workspace: MobileWorkspacePreview) {
        browserStore.closeBrowser(for: workspace.id.rawValue)
        if let previous = browserStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue),
           previous.id != panelID {
            Task { [weak store] in await store?.stopMobileBrowserStream(panelID: previous.id) }
        }
        _ = browserStreamStore.activate(panelID: panelID, in: workspace.rpcWorkspaceID.rawValue)
        Task { [weak store] in await store?.startMobileBrowserStream(panelID: panelID) }
        update()
    }

    private func stopActiveBrowserStream(in workspace: MobileWorkspacePreview) {
        guard let stream = browserStreamStore.activeState(in: workspace.rpcWorkspaceID.rawValue) else { return }
        browserStreamStore.deactivate(in: workspace.rpcWorkspaceID.rawValue)
        removeBrowserStreamController(stopping: false)
        Task { [weak store] in await store?.stopMobileBrowserStream(panelID: stream.id) }
    }

    private func presentRename(_ workspace: MobileWorkspacePreview) {
        let alert = UIAlertController(
            title: L10n.string("mobile.workspace.rename", defaultValue: "Rename Workspace"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = workspace.name
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "MobileWorkspaceRenameField"
        }
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.save", defaultValue: "Save"), style: .default) { [weak self, weak alert] _ in
            guard let self, let title = alert?.textFields?.first?.text else { return }
            Task { _ = await store.renameWorkspace(id: workspace.id, title: title) }
        })
        present(alert, animated: true)
    }

    private func confirmClose(_ workspace: MobileWorkspacePreview) {
        let alert = UIAlertController(
            title: L10n.string("mobile.workspace.delete.confirmTitle", defaultValue: "Delete Workspace?"),
            message: L10n.string("mobile.workspace.delete.confirmMessage", defaultValue: "This will close the workspace on your Mac."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("mobile.workspace.delete.confirmAction", defaultValue: "Delete"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                _ = await store.closeWorkspace(id: workspace.id)
                navigationController?.popViewController(animated: true)
            }
        })
        present(alert, animated: true)
    }

    private func presentArtifactGallery(workspaceID: String, surfaceID: String) {
        let controller = MobileTerminalArtifactViewController(
            store: store,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            toastCenter: toastCenter
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    private func presentArtifact(
        path: String,
        workspace: MobileWorkspacePreview,
        terminal: MobileTerminalPreview
    ) {
        let selection = terminalArtifactSelection(
            path: path,
            workspace: workspace,
            terminal: terminal
        )
        let controller = ChatArtifactViewerController(
            path: selection.path,
            scope: selection.sessionID == nil ? .terminal : .chat,
            loader: artifactLoader(
                workspaceID: workspace.id.rawValue,
                surfaceID: terminal.id.rawValue,
                sessionID: selection.sessionID
            ),
            toastCenter: toastCenter,
            onDone: { [weak self] in self?.navigationController?.popViewController(animated: true) }
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func terminalArtifactSelection(
        path: String,
        workspace: MobileWorkspacePreview,
        terminal: MobileTerminalPreview
    ) -> (path: String, sessionID: String?) {
        let session = chatSession(for: terminal)
        if (path as NSString).isAbsolutePath {
            return ((path as NSString).standardizingPath, session?.id)
        }
        if let session,
           let workingDirectory = session.workingDirectory,
           (workingDirectory as NSString).isAbsolutePath {
            let resolved = ((workingDirectory as NSString).appendingPathComponent(path) as NSString)
                .standardizingPath
            return (resolved, session.id)
        }
        return (path, nil)
    }

    private func artifactLoader(
        workspaceID: String,
        surfaceID: String,
        sessionID: String?
    ) -> ChatArtifactLoader {
        guard let source = store.makeChatEventSource() else {
            return .unsupported(cache: terminalArtifactThumbnailCache)
        }
        if let sessionID, store.supportsChatArtifacts {
            return ChatArtifactLoader(
                source: source,
                sessionID: sessionID,
                cache: terminalArtifactThumbnailCache
            )
        }
        return ChatArtifactLoader(
            terminalWorkspaceID: workspaceID,
            terminalSurfaceID: surfaceID,
            supportsArtifacts: store.supportsTerminalArtifacts,
            supportsDirectoryBrowsing: store.supportsTerminalArtifactList,
            cache: terminalArtifactThumbnailCache,
            stat: { path in
                try await source.terminalArtifactStat(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path
                )
            },
            fetch: { path, progress in
                try await source.terminalArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    progress: progress
                )
            },
            stream: { path, onChunk in
                try await source.terminalArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    onChunk: onChunk
                )
            },
            thumbnail: { path, maxDimension in
                try await source.terminalArtifactThumbnail(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    maxDimension: maxDimension
                )
            },
            list: { path in
                try await source.terminalArtifactList(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path
                )
            }
        )
    }
}

@MainActor
private final class PaddingLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: 8, dy: 4))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 16, height: size.height + 8)
    }
}

@MainActor
final class MobilePairingViewController: UITableViewController, UITextFieldDelegate {
    private enum Row: Int, CaseIterable {
        case name
        case host
        case port
        case connect
        case scan
        case warning
        case error
    }

    private let coordinator: MobileRootCoordinator
    private let analytics: any AnalyticsEmitting
    private let nameField = UITextField()
    private let hostField = UITextField()
    private let portField = UITextField()
    private var pairingTask: Task<Void, Never>?

    init(coordinator: MobileRootCoordinator, analytics: any AnalyticsEmitting) {
        self.coordinator = coordinator
        self.analytics = analytics
        super.init(style: .insetGrouped)
        title = L10n.string("mobile.addDevice.title", defaultValue: "Add Computer")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { pairingTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.coordinator.dismissPairing() }
        )
        configure(
            nameField,
            text: UITestConfig.addDeviceName
                ?? L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac"),
            placeholder: L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac"),
            identifier: "MobileAddDeviceNameField"
        )
        configure(
            hostField,
            text: UITestConfig.addDeviceHost ?? "",
            placeholder: L10n.string(
                "mobile.addDevice.hostPlaceholder",
                defaultValue: "127.0.0.1 (simulator only)"
            ),
            identifier: "MobileAddDeviceHostField"
        )
        hostField.keyboardType = .URL
        configure(
            portField,
            text: UITestConfig.addDevicePort ?? "\(CmxMobileDefaults.defaultHostPort)",
            placeholder: L10n.string("mobile.addDevice.portPlaceholder", defaultValue: "58465"),
            identifier: "MobileAddDevicePortField"
        )
        portField.keyboardType = .numberPad
        tableView.keyboardDismissMode = .interactive
        tableView.accessibilityIdentifier = "MobileAddDeviceForm"
    }

    func update() {
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    private func configure(
        _ field: UITextField,
        text: String,
        placeholder: String,
        identifier: String
    ) {
        field.text = text
        field.placeholder = placeholder
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = self
        field.accessibilityIdentifier = identifier
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.filter(isVisible).count
    }

    private var visibleRows: [Row] { Row.allCases.filter(isVisible) }

    private func isVisible(_ row: Row) -> Bool {
        switch row {
        case .warning: coordinator.store.pairingVersionWarning != nil
        case .error: coordinator.store.connectionError != nil
        default: true
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = visibleRows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch row {
        case .name:
            mount(nameField, in: cell)
        case .host:
            mount(hostField, in: cell)
        case .port:
            mount(portField, in: cell)
        case .connect:
            cell.textLabel?.text = L10n.string("mobile.addDevice.connect", defaultValue: "Connect")
            cell.textLabel?.textColor = view.tintColor
            cell.textLabel?.textAlignment = .center
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "MobileAddDeviceConnectButton"
        case .scan:
            cell.textLabel?.text = L10n.string("mobile.pairing.scan", defaultValue: "Scan QR Code")
            cell.imageView?.image = UIImage(systemName: "qrcode.viewfinder")
            cell.textLabel?.textColor = view.tintColor
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "MobileScanQRCodeButton"
        case .warning:
            cell.textLabel?.text = L10n.string(
                "mobile.pairing.versionWarningTitle",
                defaultValue: "Compatibility mismatch"
            )
            cell.detailTextLabel?.text = coordinator.store.pairingVersionWarning
            cell.detailTextLabel?.numberOfLines = 0
            cell.imageView?.image = UIImage(systemName: "exclamationmark.triangle.fill")
            cell.imageView?.tintColor = .systemOrange
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "MobilePairingVersionWarning"
        case .error:
            cell.textLabel?.text = coordinator.store.connectionError
            cell.detailTextLabel?.text = coordinator.store.connectionErrorGuidance
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.numberOfLines = 0
            cell.detailTextLabel?.numberOfLines = 0
            cell.accessibilityIdentifier = "MobilePairingError"
        }
        return cell
    }

    private func mount(_ field: UITextField, in cell: UITableViewCell) {
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch visibleRows[indexPath.row] {
        case .connect:
            connectManualHost()
        case .scan:
            coordinator.presentPairingScanner(entry: .settingsReplay)
            analytics.capture("ios_pairing_scanner_opened", [
                "entry": .string(coordinator.pairingPresentation.analyticsEntry),
            ])
        case .warning:
            pairingTask?.cancel()
            pairingTask = Task { [weak self] in
                guard let self else { return }
                _ = await coordinator.store.acceptPairingVersionWarning()
                coordinator.observedStateDidChange()
            }
        default:
            break
        }
    }

    private func connectManualHost() {
        guard let port = Int(portField.text ?? ""),
              !(hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let name = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            guard let self else { return }
            await coordinator.store.connectManualHost(name: name, host: host, port: port)
            coordinator.observedStateDidChange()
        }
    }
}
#endif
