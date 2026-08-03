import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxNotifications
import CmuxSettings
import CmuxSimulatorUI

@MainActor
struct PanelContentConfiguration {
    let panel: any Panel
    let workspaceID: UUID
    let paneID: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool
    let pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let customSidebarTabManager: TabManager?
    let customSidebarUnread: SidebarUnreadModel
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    let paneOwnershipOverride: Bool?
    let terminalPaneOwnershipResolver: (@MainActor () -> Bool)?
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
        case agentSession
        case simulator
        case simulatorDisabled
        case extensionBrowser
        case mobilePairing
        case accountSignIn
        case transitional(String)
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
        default:
            return .transitional(configuration.panel.panelType.rawValue)
        }
    }

    private func makeController(
        configuration: PanelContentConfiguration,
        kind: ContentKind
    ) -> NSViewController {
        switch kind {
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
        case .transitional:
            return TransitionalPanelLeafHostingController(configuration: configuration)
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
