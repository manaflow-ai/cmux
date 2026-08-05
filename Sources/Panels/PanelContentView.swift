import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxFeedback
import CmuxNotifications
import CmuxSettings
import CmuxSettingsUI
import CmuxSimulatorUI
import Combine

@MainActor
struct PanelContentConfiguration {
    let panel: any Panel
    let workspaceID: UUID
    let paneID: PaneID
    var isFocused: Bool
    let isSelectedInPane: Bool
    var isVisibleInUI: Bool
    var allowsPointerInput: Bool
    let pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot?
    let customSidebarTabManager: TabManager?
    let customSidebarUnread: SidebarUnreadModel
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    let paneOwnershipOverride: Bool?
    let terminalPaneOwnershipResolver: (@MainActor () -> Bool)?
    let paneDropZone: DropZone?
    var settingsRuntime: SettingsRuntime? = nil
    var canvasInlineBrowserHosting = false
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onResumeAgentHibernation: () -> Void
    let onAutoResumeAgentHibernation: () -> Void
    let onTriggerFlash: () -> Void
}

@MainActor
protocol PanelContentControllerUpdating: AnyObject {
    func update(configuration: PanelContentConfiguration)
    func teardownPanelContent()
}

extension PanelContentControllerUpdating {
    func teardownPanelContent() {}
}

@MainActor
final class PanelContentViewController: NSViewController {
    private enum ContentKind: Equatable {
        case terminal
        case browser
        case agentSession
        case simulator
        case simulatorDisabled
        case extensionBrowser
        case mobilePairing
        case accountSignIn
        case rightSidebarTool
        case customSidebar
        case markdown
        case filePreview
        case cloudVMLoading
        case workspaceTodo
        case project
    }

    private let contentContainer = NSView()
    private let dropTargetView = PaneDropTargetView(frame: .zero)
    private var installedController: NSViewController?
    private var installedPanelID: UUID?
    private var installedKind: ContentKind?

    init(configuration: PanelContentConfiguration) {
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        dropTargetView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)
        root.addSubview(dropTargetView)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dropTargetView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dropTargetView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dropTargetView.topAnchor.constraint(equalTo: root.topAnchor),
            dropTargetView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func update(configuration: PanelContentConfiguration) {
        loadViewIfNeeded()
        updateDropTarget(configuration)
        let kind = contentKind(for: configuration)
        if installedPanelID == configuration.panel.id,
           installedKind == kind,
           let updating = installedController as? PanelContentControllerUpdating {
            updating.update(configuration: configuration)
            return
        }

        let controller = makeController(configuration: configuration, kind: kind)
        install(controller)
        installedPanelID = configuration.panel.id
        installedKind = kind
    }

    func teardown() {
        (installedController as? PanelContentControllerUpdating)?.teardownPanelContent()
        dropTargetView.dropContext = nil
        dropTargetView.hostedView = nil
        dropTargetView.draggingExited(nil)
    }

    private func contentKind(for configuration: PanelContentConfiguration) -> ContentKind {
        switch configuration.panel.panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .agentSession:
            return .agentSession
        case .simulator:
            guard let panel = configuration.panel as? SimulatorPanel,
                  CmuxFeatureFlags.shared.isSimulatorEnabled,
                  panel.isFeatureReady
            else { return .simulatorDisabled }
            return .simulator
        case .extensionBrowser:
            return .extensionBrowser
        case .mobilePairing:
            return .mobilePairing
        case .accountSignIn:
            return .accountSignIn
        case .rightSidebarTool:
            return .rightSidebarTool
        case .customSidebar:
            return .customSidebar
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .cloudVMLoading:
            return .cloudVMLoading
        case .workspaceTodo:
            return .workspaceTodo
        case .project:
            return .project
        }
    }

    private func makeController(
        configuration: PanelContentConfiguration,
        kind: ContentKind
    ) -> NSViewController {
        switch kind {
        case .terminal:
            return TerminalPanelNativeViewController(configuration: configuration)
        case .browser:
            return BrowserPanelNativeViewController(configuration: configuration)
        case .agentSession:
            return AgentSessionPanelNativeViewController(configuration: configuration)
        case .simulator:
            return SimulatorPanelNativeViewController(configuration: configuration)
        case .simulatorDisabled:
            return SimulatorDisabledPanelNativeViewController(configuration: configuration)
        case .extensionBrowser:
            return ExtensionBrowserPanelNativeViewController(configuration: configuration)
        case .mobilePairing:
            return MobilePairingPanelNativeViewController(configuration: configuration)
        case .accountSignIn:
            return AccountSignInPanelNativeViewController(configuration: configuration)
        case .rightSidebarTool:
            return RightSidebarToolPanelViewController(configuration: configuration)
        case .customSidebar:
            return CustomSidebarPanelViewController(configuration: configuration)
        case .markdown:
            return MarkdownPanelNativeViewController(configuration: configuration)
        case .filePreview:
            return FilePreviewPanelNativeViewController(configuration: configuration)
        case .cloudVMLoading:
            return CloudVMLoadingPanelNativeViewController(configuration: configuration)
        case .workspaceTodo:
            return WorkspaceTodoPanelNativeViewController(configuration: configuration)
        case .project:
            return ProjectPanelNativeViewController(configuration: configuration)
        }
    }

    private func install(_ controller: NSViewController) {
        if let installedController {
            (installedController as? PanelContentControllerUpdating)?.teardownPanelContent()
            installedController.view.removeFromSuperview()
            installedController.removeFromParent()
        }
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        installedController = controller
    }

    private func updateDropTarget(_ configuration: PanelContentConfiguration) {
        guard configuration.isVisibleInUI, shouldInstallPaneDropTarget(configuration.panel.panelType) else {
            dropTargetView.dropContext = nil
            dropTargetView.hostedView = nil
            dropTargetView.draggingExited(nil)
            dropTargetView.isHidden = true
            return
        }
        dropTargetView.isHidden = false
        dropTargetView.hostedView = nil
        dropTargetView.dropContext = PaneDropContext(
            workspaceId: configuration.workspaceID,
            panelId: configuration.panel.id,
            paneId: configuration.paneID
        )
    }

    private func shouldInstallPaneDropTarget(_ panelType: PanelType) -> Bool {
        switch panelType {
        case .terminal, .browser:
            return false
        case .markdown, .filePreview, .rightSidebarTool, .customSidebar,
             .simulator, .agentSession, .project, .extensionBrowser,
             .workspaceTodo, .cloudVMLoading, .mobilePairing, .accountSignIn:
            return true
        }
    }
}

@MainActor
private final class AgentSessionPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private let nativeView = AgentSessionPanelNativeView(frame: .zero)

    init(configuration: PanelContentConfiguration) {
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = nativeView
    }

    func update(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? AgentSessionPanel else { return }
        let defaults = UserDefaults.standard
        let maximumWidth = (defaults.object(forKey: SessionContentWidthSettings.maxWidthKey) as? Double)
            ?? SessionContentWidthSettings.noMaximumWidth
        let alignment = defaults.string(forKey: SessionContentWidthSettings.alignmentKey)
            ?? SessionContentAlignment.center.rawValue
        nativeView.update(
            panel: panel,
            isFocused: configuration.isFocused,
            isVisibleInUI: configuration.isVisibleInUI,
            backgroundColor: configuration.appearance.contentBackgroundColor,
            theme: AgentSessionWebTheme.resolve(appearance: configuration.appearance),
            sessionContentWidthPresentation: SessionContentWidthPresentation(
                storedMaximumWidth: maximumWidth,
                storedAlignment: alignment
            ),
            onRequestPanelFocus: configuration.onRequestPanelFocus
        )
    }

    func teardownPanelContent() {
        nativeView.teardown()
    }
}

@MainActor
private final class SimulatorPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private let lifecycle = SimulatorPanelLifecycleHost()
    private var simulatorController: SimulatorPaneView?

    init(configuration: PanelContentConfiguration) {
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? SimulatorPanel else { return }
        let controller: SimulatorPaneView
        if let simulatorController {
            controller = simulatorController
        } else {
            controller = SimulatorPaneView(
                coordinator: panel.coordinator,
                backgroundColor: configuration.appearance.contentBackgroundColor,
                allowsPointerInput: configuration.allowsPointerInput,
                pointerEntryEventFilter: configuration.pointerEntryEventFilter,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            )
            simulatorController = controller
            addChild(controller)
            lifecycle.installFocusOwnershipView(in: controller)
            view = controller.view
        }
        lifecycle.update(
            controller: controller,
            panel: panel,
            isFocused: configuration.isFocused,
            isVisibleInUI: configuration.isVisibleInUI,
            allowsPointerInput: configuration.allowsPointerInput,
            pointerEntryEventFilter: configuration.pointerEntryEventFilter,
            backgroundColor: configuration.appearance.contentBackgroundColor,
            onRequestPanelFocus: configuration.onRequestPanelFocus
        )
    }

    func teardownPanelContent() {
        guard let simulatorController else { return }
        lifecycle.teardown(controller: simulatorController)
        simulatorController.removeFromParent()
        self.simulatorController = nil
    }
}

@MainActor
private final class SimulatorDisabledPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private let nativeView: SimulatorFeatureDisabledNativeView

    init(configuration: PanelContentConfiguration) {
        nativeView = SimulatorFeatureDisabledNativeView(
            backgroundColor: configuration.appearance.contentBackgroundColor
        )
        super.init(nibName: nil, bundle: nil)
        view = nativeView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: PanelContentConfiguration) {
        nativeView.update(backgroundColor: configuration.appearance.contentBackgroundColor)
    }
}

@MainActor
private final class ExtensionBrowserPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private let container: CMUXSidebarExtensionBrowserContainerViewController

    init(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? CMUXSidebarExtensionBrowserPanel else {
            fatalError("extensionBrowser panel type mismatch")
        }
        container = CMUXSidebarExtensionBrowserContainerViewController(
            browserViewController: panel.browserViewController,
            onRequestPanelFocus: configuration.onRequestPanelFocus
        )
        super.init(nibName: nil, bundle: nil)
        addChild(container)
        view = container.view
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? CMUXSidebarExtensionBrowserPanel else { return }
        container.browserViewController.title = panel.displayTitle
        container.onRequestPanelFocus = configuration.onRequestPanelFocus
        container.attachBrowserIfNeeded()
        container.updateLayoutForCurrentBounds()
    }

    func teardownPanelContent() {
        container.detachBrowserForTransientReparent()
    }
}

@MainActor
private final class MobilePairingPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private let nativeView: MobilePairingView

    init(configuration: PanelContentConfiguration) {
        nativeView = MobilePairingView(
            backgroundColor: configuration.appearance.contentBackgroundColor,
            onRequestPanelFocus: configuration.onRequestPanelFocus
        )
        super.init(nibName: nil, bundle: nil)
        view = nativeView
        nativeView.setAccessibilityIdentifier("MobilePairingPanel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: PanelContentConfiguration) {
        nativeView.updatePresentation(
            backgroundColor: configuration.appearance.contentBackgroundColor,
            onRequestPanelFocus: configuration.onRequestPanelFocus
        )
    }
}

@MainActor
private final class AccountSignInPanelNativeViewController: NSViewController, PanelContentControllerUpdating {
    private let scrollView = AccountSignInPanelScrollView()
    private let signInView: AccountSignInView

    init(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? AccountSignInPanel else {
            fatalError("accountSignIn panel type mismatch")
        }
        signInView = AccountSignInView(model: panel.model, automaticallyStartsSignIn: true)
        super.init(nibName: nil, bundle: nil)
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = signInView
        scrollView.onMouseDown = configuration.onRequestPanelFocus
        scrollView.setAccessibilityIdentifier("AccountSignInPanel")
        view = scrollView
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: PanelContentConfiguration) {
        scrollView.backgroundColor = configuration.appearance.contentBackgroundColor
        scrollView.onMouseDown = configuration.onRequestPanelFocus
        signInView.frame = NSRect(
            x: 24,
            y: 24,
            width: max(0, scrollView.contentSize.width - 48),
            height: max(240, scrollView.contentSize.height - 48)
        )
    }
}

@MainActor
private final class AccountSignInPanelScrollView: NSScrollView {
    var onMouseDown: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        guard let documentView else { return }
        documentView.frame.size.width = max(0, contentSize.width - 48)
        documentView.frame.size.height = max(240, contentSize.height - 48)
    }
}

@MainActor
private final class CloudVMLoadingPanelNativeViewController: NSViewController,
    PanelContentControllerUpdating
{
    private var configuration: PanelContentConfiguration
    private weak var panel: CloudVMLoadingPanel?
    private var panelCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    private let contentStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let warningIcon = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let loadingStatus = NSStackView()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let workspaceRow = CloudVMLoadingStatusNativeRow()
    private let activeRow = CloudVMLoadingStatusNativeRow()
    private let terminalRow = CloudVMLoadingStatusNativeRow()
    private let failureMessage = NSTextField(wrappingLabelWithString: "")
    private let actionStack = NSStackView()
    private let retryButton = CloudVMLoadingActionButton(
        title: String(localized: "panel.cloudVM.loading.failed.retry", defaultValue: "Retry"),
        systemName: "arrow.clockwise"
    )
    private let feedbackButton = CloudVMLoadingActionButton(
        title: String(localized: "panel.cloudVM.loading.failed.feedback", defaultValue: "Send Feedback"),
        systemName: "bubble.left.and.text.bubble.right"
    )
    private let failureElapsed = NSTextField(labelWithString: "")

    init(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 14

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        warningIcon.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "exclamationmark.triangle.fill",
            pointSize: 18,
            weight: .regular
        )
        warningIcon.contentTintColor = .systemOrange
        headline.font = .systemFont(ofSize: 14, weight: .semibold)
        headline.alignment = .center

        elapsedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.alignment = .center
        loadingStatus.orientation = .vertical
        loadingStatus.alignment = .leading
        loadingStatus.spacing = 10
        let rows = NSStackView(views: [workspaceRow, activeRow, terminalRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        loadingStatus.addArrangedSubview(elapsedLabel)
        loadingStatus.addArrangedSubview(rows)
        rows.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        failureMessage.font = .systemFont(ofSize: 12)
        failureMessage.textColor = .secondaryLabelColor
        failureMessage.alignment = .center
        failureMessage.maximumNumberOfLines = 0
        failureMessage.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.addArrangedSubview(retryButton)
        actionStack.addArrangedSubview(feedbackButton)
        retryButton.keyEquivalent = "\r"
        retryButton.bezelColor = .controlAccentColor
        failureElapsed.font = .systemFont(ofSize: 11)
        failureElapsed.textColor = .tertiaryLabelColor
        failureElapsed.alignment = .center

        [
            spinner,
            warningIcon,
            headline,
            loadingStatus,
            failureMessage,
            actionStack,
            failureElapsed,
        ].forEach(contentStack.addArrangedSubview)
        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 32),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
        ])
        retryButton.onClick = {
            _ = AppDelegate.shared?.performCloudVMAction(debugSource: "panel.cloudVM.retry")
        }
        feedbackButton.onClick = {
            FeedbackComposerBridge().openComposer()
        }
        root.setAccessibilityIdentifier("CloudVMLoadingPanel")
        view = root
    }

    func update(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        loadViewIfNeeded()
        guard let panel = configuration.panel as? CloudVMLoadingPanel else { return }
        observe(panel)
        render(panel: panel, now: Date())
        reconcileTicker(panel: panel)
    }

    func teardownPanelContent() {
        panelCancellable = nil
        refreshTask?.cancel()
        refreshTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        retryButton.onClick = nil
        feedbackButton.onClick = nil
        panel = nil
    }

    isolated deinit {
        refreshTask?.cancel()
        tickerTask?.cancel()
    }

    private func observe(_ panel: CloudVMLoadingPanel) {
        guard self.panel !== panel else { return }
        panelCancellable = panel.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.scheduleRefresh()
            }
        }
        self.panel = panel
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            self.render(panel: panel, now: Date())
            self.reconcileTicker(panel: panel)
        }
    }

    private func reconcileTicker(panel: CloudVMLoadingPanel) {
        guard configuration.isVisibleInUI, panel.isLoading else {
            tickerTask?.cancel()
            tickerTask = nil
            return
        }
        guard tickerTask == nil else { return }
        tickerTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self, let panel = self.panel else { return }
                self.render(panel: panel, now: Date())
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func render(panel: CloudVMLoadingPanel, now: Date) {
        view.layer?.backgroundColor = GhosttyApp.shared.defaultBackgroundColor.cgColor
        switch panel.phase {
        case .loading:
            let elapsed = max(0, Int(now.timeIntervalSince(panel.startedAt).rounded(.down)))
            spinner.isHidden = false
            warningIcon.isHidden = true
            headline.stringValue = String(
                localized: "panel.cloudVM.loading.headline",
                defaultValue: "Opening Base"
            )
            loadingStatus.isHidden = false
            failureMessage.isHidden = true
            actionStack.isHidden = true
            failureElapsed.isHidden = true
            elapsedLabel.stringValue = String(format: String(
                localized: "panel.cloudVM.loading.elapsed",
                defaultValue: "%ds elapsed"
            ), elapsed)
            workspaceRow.update(
                icon: "checkmark.circle.fill",
                text: String(
                    localized: "panel.cloudVM.loading.step.workspace",
                    defaultValue: "Pinned workspace created"
                ),
                isActive: false
            )
            activeRow.update(icon: loadingStatusIcon(elapsed), text: loadingStatusText(elapsed), isActive: true)
            terminalRow.update(
                icon: elapsed >= 6 ? "arrow.triangle.2.circlepath" : "circle",
                text: String(
                    localized: "panel.cloudVM.loading.step.terminal",
                    defaultValue: "Terminal will open automatically when ready"
                ),
                isActive: elapsed >= 6
            )
        case .failed(let message, let elapsed):
            spinner.isHidden = true
            warningIcon.isHidden = false
            headline.stringValue = String(
                localized: "panel.cloudVM.loading.failed.headline",
                defaultValue: "Base unavailable"
            )
            loadingStatus.isHidden = true
            failureMessage.isHidden = false
            failureMessage.stringValue = message
            actionStack.isHidden = false
            failureElapsed.isHidden = false
            failureElapsed.stringValue = String(format: String(
                localized: "panel.cloudVM.loading.failed.elapsed",
                defaultValue: "Waited %ds before stopping."
            ), elapsed)
        }
    }

    private func loadingStatusText(_ elapsed: Int) -> String {
        switch elapsed {
        case 0..<3:
            String(
                localized: "panel.cloudVM.loading.step.request",
                defaultValue: "Requesting your persistent VM"
            )
        case 3..<8:
            String(
                localized: "panel.cloudVM.loading.step.resume",
                defaultValue: "Starting or resuming the VM"
            )
        case 8..<18:
            String(
                localized: "panel.cloudVM.loading.step.endpoint",
                defaultValue: "Waiting for a secure terminal endpoint"
            )
        default:
            String(
                localized: "panel.cloudVM.loading.step.retrying",
                defaultValue: "Still waiting; retrying in the background"
            )
        }
    }

    private func loadingStatusIcon(_ elapsed: Int) -> String {
        (0..<6).contains(elapsed) ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }
}

@MainActor
private final class CloudVMLoadingStatusNativeRow: NSView {
    private let iconView = NSImageView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 12)
        textLabel.maximumNumberOfLines = 2
        addSubview(iconView)
        addSubview(textLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            textLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            textLabel.topAnchor.constraint(equalTo: topAnchor),
            textLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(icon: String, text: String, isActive: Bool) {
        iconView.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: icon,
            pointSize: 12,
            weight: .regular
        )
        let color = isActive ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        iconView.contentTintColor = color
        textLabel.textColor = color
        textLabel.stringValue = text
    }
}

@MainActor
private final class CloudVMLoadingActionButton: NSButton {
    var onClick: (() -> Void)?

    init(title: String, systemName: String) {
        super.init(frame: .zero)
        self.title = title
        image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: 12,
            weight: .semibold
        )
        imagePosition = .imageLeading
        font = .systemFont(ofSize: 12, weight: .semibold)
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        onClick?()
    }
}
