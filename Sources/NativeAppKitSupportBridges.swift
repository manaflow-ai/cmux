import Bonsplit
import AVKit
import Combine
import CmuxAppKitSupportUI
import CmuxFeedback
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSettingsUI
import CmuxSimulatorUI
import CmuxSidebarProviderKit
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
@_spi(CmuxHostTransport) import CmuxSidebar
@_spi(CmuxHostTransport) import CmuxExtensionKit
import ExtensionFoundation
import SwiftUI

extension View {
    func sidebarWorkspaceObservations(
        ids: [UUID],
        workspaces: [Workspace],
        debouncedInterval: DispatchQueue.SchedulerTimeType.Stride,
        onChange: @MainActor @escaping (UUID) -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            await WorkspaceSidebarObservationTasks.observeWorkspaces(
                ids: ids,
                workspaces: workspaces,
                debouncedInterval: debouncedInterval,
                onChange: onChange
            )
        }
    }

    func sidebarAgentRuntimeObservation(
        id: UUID,
        model: WorkspaceSidebarAgentRuntimeObservationModel,
        onChange: @MainActor @escaping () -> Void
    ) -> some View {
        task(id: id) { @MainActor in
            await WorkspaceSidebarObservationTasks.observeAgentRuntime(model: model, onChange: onChange)
        }
    }

    func sidebarProcessTitleObservation(
        id: UUID,
        model: WorkspaceSidebarProcessTitleObservationModel,
        onChange: @MainActor @escaping () -> Void
    ) -> some View {
        task(id: id) { @MainActor in
            await WorkspaceSidebarObservationTasks.observeProcessTitle(model: model, onChange: onChange)
        }
    }

    func sidebarProcessTitleObservations(
        ids: [UUID],
        models: [WorkspaceSidebarProcessTitleObservationModel],
        onChange: @MainActor @escaping () -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            await WorkspaceSidebarObservationTasks.observeAggregateProcessTitles(
                models: models,
                onChange: onChange
            )
        }
    }

    func sidebarProcessTitleObservations(
        ids: [UUID],
        models: [WorkspaceSidebarProcessTitleObservationModel],
        onChange: @MainActor @escaping (UUID) -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            await WorkspaceSidebarObservationTasks.observeProcessTitles(
                ids: ids,
                models: models,
                onChange: onChange
            )
        }
    }

    func sidebarAgentRuntimeObservations(
        ids: [UUID],
        models: [WorkspaceSidebarAgentRuntimeObservationModel],
        onChange: @MainActor @escaping (UUID) -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            await WorkspaceSidebarObservationTasks.observeAgentRuntimes(
                ids: ids,
                models: models,
                onChange: onChange
            )
        }
    }
}

struct ConfigSettingsView: NSViewControllerRepresentable {
    static let windowID = ConfigSettingsViewController.windowID

    func makeNSViewController(context: Context) -> ConfigSettingsViewController {
        ConfigSettingsViewController()
    }

    func updateNSViewController(
        _ viewController: ConfigSettingsViewController,
        context: Context
    ) {}
}

struct CmuxExtensionSidebarWorkspaceRowView: NSViewRepresentable, Equatable {
    let row: CmuxSidebarProviderRow
    let workspace: CmuxSidebarProviderWorkspace?
    let providerId: String
    let relativeNow: Date
    let isSelected: Bool
    let onSelect: (UUID) -> Void
    let onOpenWindow: (CmuxSidebarProviderWorkspace) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row &&
            lhs.workspace == rhs.workspace &&
            lhs.providerId == rhs.providerId &&
            lhs.relativeNow == rhs.relativeNow &&
            lhs.isSelected == rhs.isSelected
    }

    func makeNSView(context: Context) -> CmuxExtensionSidebarWorkspaceRowNativeView {
        CmuxExtensionSidebarWorkspaceRowNativeView()
    }

    func updateNSView(_ view: CmuxExtensionSidebarWorkspaceRowNativeView, context: Context) {
        view.update(
            row: row,
            workspace: workspace,
            providerID: providerId,
            relativeNow: relativeNow,
            isSelected: isSelected,
            onSelect: onSelect,
            onOpenWindow: onOpenWindow
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CmuxExtensionSidebarWorkspaceRowNativeView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: 32)
    }
}

struct BrowserDownloadsToolbarButton: NSViewRepresentable {
    let downloads: [BrowserDownloadRecord]
    let isDownloading: Bool
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let onOpen: (BrowserDownloadRecord) -> Void
    let onReveal: (BrowserDownloadRecord) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> BrowserDownloadsToolbarButtonView {
        BrowserDownloadsToolbarButtonView()
    }

    func updateNSView(_ view: BrowserDownloadsToolbarButtonView, context: Context) {
        view.update(
            downloads: downloads,
            isDownloading: isDownloading,
            iconPointSize: iconPointSize,
            hitSize: hitSize,
            onOpen: onOpen,
            onReveal: onReveal,
            onClear: onClear
        )
    }

    static func dismantleNSView(_ view: BrowserDownloadsToolbarButtonView, coordinator: ()) {
        view.teardown()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: BrowserDownloadsToolbarButtonView,
        context: Context
    ) -> CGSize? {
        CGSize(width: hitSize, height: hitSize)
    }
}

struct DockPanelView: NSViewControllerRepresentable {
    let store: DockSplitStore
    let isSidebarVisible: Bool
    let mode: RightSidebarMode
    let rootDirectory: String?
    let windowAppearance: WindowAppearanceSnapshot
    var rightSidebarOwnsInputFocus: Bool = false
    let unreadSource: SidebarUnreadModel

    func makeNSViewController(context: Context) -> DockPanelViewController {
        DockPanelViewController(
            store: store,
            isSidebarVisible: isSidebarVisible,
            mode: mode,
            rootDirectory: rootDirectory,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
            unreadSource: unreadSource
        )
    }

    func updateNSViewController(_ controller: DockPanelViewController, context: Context) {
        controller.update(
            isSidebarVisible: isSidebarVisible,
            mode: mode,
            rootDirectory: rootDirectory,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus
        )
    }

    static func dismantleNSViewController(_ controller: DockPanelViewController, coordinator: ()) {
        controller.teardown()
    }
}

struct RemoteTmuxWindowMirrorSplitView: NSViewControllerRepresentable {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isOuterFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onOuterFocus: () -> Void
    var unreadSurfaceIDs: Set<UUID> = []

    func makeNSViewController(context: Context) -> RemoteTmuxWindowMirrorSplitViewController {
        RemoteTmuxWindowMirrorSplitViewController(
            mirror: mirror,
            appearance: appearance,
            isOuterFocused: isOuterFocused,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            onOuterFocus: onOuterFocus,
            unreadSurfaceIDs: unreadSurfaceIDs
        )
    }

    func updateNSViewController(
        _ controller: RemoteTmuxWindowMirrorSplitViewController,
        context: Context
    ) {
        controller.update(
            appearance: appearance,
            isOuterFocused: isOuterFocused,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            onOuterFocus: onOuterFocus,
            unreadSurfaceIDs: unreadSurfaceIDs
        )
    }

    static func dismantleNSViewController(
        _ controller: RemoteTmuxWindowMirrorSplitViewController,
        coordinator: ()
    ) {
        controller.teardown()
    }
}

struct NotificationsPage: NSViewControllerRepresentable {
    @EnvironmentObject private var notificationStore: TerminalNotificationStore
    @EnvironmentObject private var tabManager: TabManager
    @Binding var selection: SidebarSelection

    func makeNSViewController(context: Context) -> NotificationsPageViewController {
        NotificationsPageViewController(
            notificationStore: notificationStore,
            tabManager: tabManager,
            selection: { selection },
            setSelection: { selection = $0 }
        )
    }

    func updateNSViewController(_ controller: NotificationsPageViewController, context: Context) {
        controller.updateSelection(
            selection: { selection },
            setSelection: { selection = $0 }
        )
    }

    static func dismantleNSViewController(
        _ controller: NotificationsPageViewController,
        coordinator: ()
    ) {
        controller.teardown()
    }
}

struct PanelContentView: NSViewControllerRepresentable {
    @Environment(\.paneDropZone) private var paneDropZone
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let isFocused: Bool
    let isSelectedInPane: Bool
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool
    var pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let portalPriority: Int
    let isSplit: Bool
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let customSidebarTabManager: TabManager?
    let customSidebarUnread: SidebarUnreadModel
    let hasUnreadNotification: Bool
    let terminalAgentContext: String
    var paneOwnershipOverride: Bool?
    var terminalPaneOwnershipResolver: (@MainActor () -> Bool)?
    let onFocus: () -> Void
    let onRequestPanelFocus: () -> Void
    let onResumeAgentHibernation: () -> Void
    let onAutoResumeAgentHibernation: () -> Void
    let onTriggerFlash: () -> Void

    init(
        panel: any Panel,
        workspaceId: UUID,
        paneId: PaneID,
        isFocused: Bool,
        isSelectedInPane: Bool,
        isVisibleInUI: Bool,
        allowsPointerInput: Bool,
        pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)? = nil,
        portalPriority: Int,
        isSplit: Bool,
        appearance: PanelAppearance,
        windowAppearance: WindowAppearanceSnapshot,
        customSidebarTabManager: TabManager?,
        customSidebarUnread: SidebarUnreadModel = TerminalNotificationStore.shared.sidebarUnread,
        hasUnreadNotification: Bool,
        terminalAgentContext: String,
        paneOwnershipOverride: Bool? = nil,
        terminalPaneOwnershipResolver: (@MainActor () -> Bool)? = nil,
        onFocus: @escaping () -> Void,
        onRequestPanelFocus: @escaping () -> Void,
        onResumeAgentHibernation: @escaping () -> Void,
        onAutoResumeAgentHibernation: @escaping () -> Void,
        onTriggerFlash: @escaping () -> Void
    ) {
        self.panel = panel
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.isFocused = isFocused
        self.isSelectedInPane = isSelectedInPane
        self.isVisibleInUI = isVisibleInUI
        self.allowsPointerInput = allowsPointerInput
        self.pointerEntryEventFilter = pointerEntryEventFilter
        self.portalPriority = portalPriority
        self.isSplit = isSplit
        self.appearance = appearance
        self.windowAppearance = windowAppearance
        self.customSidebarTabManager = customSidebarTabManager
        self.customSidebarUnread = customSidebarUnread
        self.hasUnreadNotification = hasUnreadNotification
        self.terminalAgentContext = terminalAgentContext
        self.paneOwnershipOverride = paneOwnershipOverride
        self.terminalPaneOwnershipResolver = terminalPaneOwnershipResolver
        self.onFocus = onFocus
        self.onRequestPanelFocus = onRequestPanelFocus
        self.onResumeAgentHibernation = onResumeAgentHibernation
        self.onAutoResumeAgentHibernation = onAutoResumeAgentHibernation
        self.onTriggerFlash = onTriggerFlash
    }

    func makeNSViewController(context: Context) -> PanelContentViewController {
        PanelContentViewController(configuration: configuration)
    }

    func updateNSViewController(_ controller: PanelContentViewController, context: Context) {
        controller.update(configuration: configuration)
    }

    static func dismantleNSViewController(_ controller: PanelContentViewController, coordinator: ()) {
        controller.teardown()
    }

    private var configuration: PanelContentConfiguration {
        PanelContentConfiguration(
            panel: panel,
            workspaceID: workspaceId,
            paneID: paneId,
            isFocused: isFocused,
            isSelectedInPane: isSelectedInPane,
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            portalPriority: portalPriority,
            isSplit: isSplit,
            appearance: appearance,
            windowAppearance: windowAppearance,
            customSidebarTabManager: customSidebarTabManager,
            customSidebarUnread: customSidebarUnread,
            hasUnreadNotification: hasUnreadNotification,
            terminalAgentContext: terminalAgentContext,
            paneOwnershipOverride: paneOwnershipOverride,
            terminalPaneOwnershipResolver: terminalPaneOwnershipResolver,
            paneDropZone: paneDropZone,
            onFocus: onFocus,
            onRequestPanelFocus: onRequestPanelFocus,
            onResumeAgentHibernation: onResumeAgentHibernation,
            onAutoResumeAgentHibernation: onAutoResumeAgentHibernation,
            onTriggerFlash: onTriggerFlash
        )
    }
}

struct WorkspaceCanvasHostView: NSViewControllerRepresentable {
    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot

    @Environment(\.settingsRuntime) private var settingsRuntime
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedSessionContentMaximumWidth = SessionContentWidthSettings.noMaximumWidth
    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedSessionContentAlignment = SessionContentAlignment.center.rawValue

    func makeNSViewController(context: Context) -> WorkspaceCanvasHostController {
        WorkspaceCanvasHostController(configuration: configuration)
    }

    func updateNSViewController(_ controller: WorkspaceCanvasHostController, context: Context) {
        controller.update(configuration: configuration)
    }

    static func dismantleNSViewController(
        _ controller: WorkspaceCanvasHostController,
        coordinator: ()
    ) {
        controller.teardown()
    }

    private var configuration: WorkspaceCanvasHostConfiguration {
        WorkspaceCanvasHostConfiguration(
            workspace: workspace,
            isWorkspaceVisible: isWorkspaceVisible,
            isWorkspaceInputActive: isWorkspaceInputActive,
            portalPriority: portalPriority,
            appearance: appearance,
            windowAppearance: windowAppearance,
            settingsRuntime: settingsRuntime,
            sessionContentWidthPresentation: SessionContentWidthPresentation(
                storedMaximumWidth: storedSessionContentMaximumWidth,
                storedAlignment: storedSessionContentAlignment
            )
        )
    }
}

struct CommandPaletteCommandListRenderView: NSViewRepresentable {
    let renderModel: CommandPaletteOverlayRenderModel
    let onRunResult: (String) -> Void

    func makeNSView(context: Context) -> CommandPaletteCommandListNativeView {
        CommandPaletteCommandListNativeView(
            renderModel: renderModel,
            onRunResult: onRunResult
        )
    }

    func updateNSView(_ view: CommandPaletteCommandListNativeView, context: Context) {
        view.update(renderModel: renderModel, onRunResult: onRunResult)
    }
}

@MainActor
final class TransitionalPanelLeafHostingController: NSHostingController<AnyView>,
    PanelContentControllerUpdating
{
    private var configuration: PanelContentConfiguration

    init(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = []
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: PanelContentConfiguration) {
        self.configuration = configuration
        render()
    }

    private func render() {
        let configuration = configuration
        let panel = configuration.panel
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return setEmpty() }
            rootView = AnyView(TerminalPanelView(
                panel: terminalPanel,
                paneId: configuration.paneID,
                isFocused: configuration.isFocused,
                isVisibleInUI: configuration.isVisibleInUI,
                portalPaneOwnershipResolver: configuration.terminalPaneOwnershipResolver,
                portalPriority: configuration.portalPriority,
                isSplit: configuration.isSplit,
                appearance: configuration.appearance,
                hasUnreadNotification: configuration.hasUnreadNotification,
                terminalAgentContext: configuration.terminalAgentContext,
                onFocus: configuration.onFocus,
                onResumeAgentHibernation: configuration.onResumeAgentHibernation,
                onAutoResumeAgentHibernation: configuration.onAutoResumeAgentHibernation,
                onTriggerFlash: configuration.onTriggerFlash
            ).environment(\.paneDropZone, configuration.paneDropZone))
        case .browser:
            guard let browserPanel = panel as? BrowserPanel else { return setEmpty() }
            rootView = AnyView(BrowserPanelView(
                panel: browserPanel,
                paneId: configuration.paneID,
                isFocused: configuration.isFocused,
                isVisibleInUI: configuration.isVisibleInUI,
                portalPriority: configuration.portalPriority,
                paneOwnershipOverride: configuration.paneOwnershipOverride,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            ).id(browserPanel.id).environment(\.paneDropZone, configuration.paneDropZone))
        case .markdown:
            guard let markdownPanel = panel as? MarkdownPanel else { return setEmpty() }
            rootView = AnyView(MarkdownPanelView(
                panel: markdownPanel,
                isFocused: configuration.isFocused,
                isVisibleInUI: configuration.isVisibleInUI,
                portalPriority: configuration.portalPriority,
                appearance: configuration.appearance,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            ))
        case .filePreview:
            guard let filePreviewPanel = panel as? FilePreviewPanel else { return setEmpty() }
            rootView = AnyView(FilePreviewPanelView(
                panel: filePreviewPanel,
                isFocused: configuration.isFocused,
                isVisibleInUI: configuration.isVisibleInUI,
                portalPriority: configuration.portalPriority,
                appearance: configuration.appearance,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            ))
        case .rightSidebarTool:
            guard let toolPanel = panel as? RightSidebarToolPanel else { return setEmpty() }
            rootView = AnyView(RightSidebarToolPanelView(
                panel: toolPanel,
                isFocused: configuration.isFocused,
                isVisibleInUI: configuration.isVisibleInUI,
                appearance: configuration.appearance,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            ))
        case .customSidebar:
            guard let sidebarPanel = panel as? CustomSidebarPanel,
                  let tabManager = configuration.customSidebarTabManager,
                  let windowAppearance = configuration.windowAppearance
            else { return setEmpty() }
            rootView = AnyView(CustomSidebarPanelView(
                panel: sidebarPanel,
                tabManager: tabManager,
                sidebarUnread: configuration.customSidebarUnread,
                isFocused: configuration.isFocused,
                isVisibleInUI: configuration.isVisibleInUI,
                appearance: configuration.appearance,
                windowAppearance: windowAppearance,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            ))
        case .project:
            guard let projectPanel = panel as? ProjectPanel else { return setEmpty() }
            rootView = AnyView(ProjectPanelView(
                panel: projectPanel,
                isFocused: configuration.isFocused,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            ))
        case .workspaceTodo:
            guard let todoPanel = panel as? WorkspaceTodoPanel else { return setEmpty() }
            rootView = AnyView(WorkspaceTodoPanelView(
                panel: todoPanel,
                isFocused: configuration.isFocused,
                onRequestPanelFocus: configuration.onRequestPanelFocus
            ))
        case .cloudVMLoading:
            guard let loadingPanel = panel as? CloudVMLoadingPanel else { return setEmpty() }
            rootView = AnyView(CloudVMLoadingPanelView(panel: loadingPanel))
        case .simulator, .agentSession, .extensionBrowser, .mobilePairing, .accountSignIn:
            setEmpty()
        }
        rootView = AnyView(
            rootView
                .environment(\.settingsRuntime, configuration.settingsRuntime)
                .environment(\.cmuxCanvasInlineBrowserHosting, configuration.canvasInlineBrowserHosting)
        )
    }

    private func setEmpty() {
        rootView = AnyView(EmptyView())
    }
}

private struct CloudVMLoadingPanelView: View {
    @ObservedObject var panel: CloudVMLoadingPanel

    var body: some View {
        TimelineView(.periodic(from: panel.startedAt, by: 1)) { context in
            let elapsedSeconds = max(0, Int(context.date.timeIntervalSince(panel.startedAt).rounded(.down)))
            VStack(spacing: 14) {
                switch panel.phase {
                case .loading:
                    ProgressView().controlSize(.small)
                    Text(String(localized: "panel.cloudVM.loading.headline", defaultValue: "Opening Base"))
                        .cmuxFont(size: 14, weight: .semibold)
                    CloudVMLoadingStatusView(elapsedSeconds: elapsedSeconds)
                case .failed(let message, let failedElapsedSeconds):
                    CmuxSystemSymbolImage(systemName: "exclamationmark.triangle.fill", pointSize: 18)
                        .foregroundStyle(.orange)
                    Text(String(localized: "panel.cloudVM.loading.failed.headline", defaultValue: "Base unavailable"))
                        .cmuxFont(size: 14, weight: .semibold)
                    Text(message)
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    HStack(spacing: 8) {
                        Button {
                            _ = AppDelegate.shared?.performCloudVMAction(debugSource: "panel.cloudVM.retry")
                        } label: {
                            Label(
                                String(localized: "panel.cloudVM.loading.failed.retry", defaultValue: "Retry"),
                                systemImage: "arrow.clockwise"
                            )
                            .cmuxFont(size: 12, weight: .semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button {
                            FeedbackComposerBridge().openComposer()
                        } label: {
                            Label(
                                String(localized: "panel.cloudVM.loading.failed.feedback", defaultValue: "Send Feedback"),
                                systemImage: "bubble.left.and.text.bubble.right"
                            )
                            .cmuxFont(size: 12, weight: .semibold)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text(String(format: String(
                        localized: "panel.cloudVM.loading.failed.elapsed",
                        defaultValue: "Waited %ds before stopping."
                    ), failedElapsedSeconds))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
        }
    }
}

private struct CloudVMLoadingStatusView: View {
    let elapsedSeconds: Int

    var body: some View {
        VStack(spacing: 10) {
            Text(String(format: String(
                localized: "panel.cloudVM.loading.elapsed",
                defaultValue: "%ds elapsed"
            ), elapsedSeconds))
            .cmuxFont(size: 12, weight: .medium)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                CloudVMLoadingStatusRow(
                    icon: "checkmark.circle.fill",
                    text: String(localized: "panel.cloudVM.loading.step.workspace", defaultValue: "Pinned workspace created"),
                    isActive: false
                )
                CloudVMLoadingStatusRow(icon: statusIcon, text: statusText, isActive: true)
                CloudVMLoadingStatusRow(
                    icon: elapsedSeconds >= 6 ? "arrow.triangle.2.circlepath" : "circle",
                    text: String(localized: "panel.cloudVM.loading.step.terminal", defaultValue: "Terminal will open automatically when ready"),
                    isActive: elapsedSeconds >= 6
                )
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var statusText: String {
        switch elapsedSeconds {
        case 0..<3: String(localized: "panel.cloudVM.loading.step.request", defaultValue: "Requesting your persistent VM")
        case 3..<8: String(localized: "panel.cloudVM.loading.step.resume", defaultValue: "Starting or resuming the VM")
        case 8..<18: String(localized: "panel.cloudVM.loading.step.endpoint", defaultValue: "Waiting for a secure terminal endpoint")
        default: String(localized: "panel.cloudVM.loading.step.retrying", defaultValue: "Still waiting; retrying in the background")
        }
    }

    private var statusIcon: String {
        (0..<6).contains(elapsedSeconds) ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }
}

private struct CloudVMLoadingStatusRow: View {
    let icon: String
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(systemName: icon, pointSize: 12)
                .foregroundStyle(isActive ? .secondary : .tertiary)
                .frame(width: 14)
            Text(text)
                .cmuxFont(size: 12)
                .foregroundStyle(isActive ? .secondary : .tertiary)
                .lineLimit(2)
        }
    }
}

struct PanelFilePathHeader<TrailingContent: View>: View {
    let iconSystemName: String
    let filePath: String
    let foregroundColor: NSColor
    @ViewBuilder let trailingContent: () -> TrailingContent

    var body: some View {
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(systemName: iconSystemName, pointSize: 16)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(filePath)
                .cmuxFont(size: 11, design: .monospaced)
                .foregroundStyle(Color(nsColor: foregroundColor).opacity(0.68))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            trailingContent()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.clear)
    }
}

struct PanelHeaderIconButton: View {
    let systemName: String
    let label: String
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelHeaderIconGlyph(systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PanelHeaderIconGlyph: View {
    let systemName: String

    var body: some View {
        CmuxSystemSymbolImage(systemName: systemName, pointSize: 13)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }
}

struct ShortcutDiscoveryButton: NSViewRepresentable {
    @Binding var isPopoverPresented: Bool

    func makeNSView(context: Context) -> ShortcutDiscoveryButtonView {
        ShortcutDiscoveryButtonView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    }

    func updateNSView(_ view: ShortcutDiscoveryButtonView, context: Context) {
        view.update(isPresented: isPopoverPresented) { presented in
            isPopoverPresented = presented
        }
    }

    static func dismantleNSView(_ view: ShortcutDiscoveryButtonView, coordinator: ()) {
        view.teardown()
    }
}

struct CMUXSidebarExtensionBrowserPanelView: NSViewControllerRepresentable {
    let panel: CMUXSidebarExtensionBrowserPanel
    let onRequestPanelFocus: () -> Void

    func makeNSViewController(context: Context) -> CMUXSidebarExtensionBrowserContainerViewController {
        CMUXSidebarExtensionBrowserContainerViewController(
            browserViewController: panel.browserViewController,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }

    func updateNSViewController(
        _ container: CMUXSidebarExtensionBrowserContainerViewController,
        context: Context
    ) {
        container.browserViewController.title = panel.displayTitle
        container.onRequestPanelFocus = onRequestPanelFocus
        container.attachBrowserIfNeeded()
        container.updateLayoutForCurrentBounds()
    }

    static func dismantleNSViewController(
        _ container: CMUXSidebarExtensionBrowserContainerViewController,
        coordinator: ()
    ) {
        container.detachBrowserForTransientReparent()
    }
}

struct SidebarBonsplitTabNewWorkspaceDropOverlay: NSViewRepresentable {
    let tabManager: TabManager
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @Binding var dropIndicator: SidebarDropIndicator?

    func makeNSView(context: Context) -> SidebarBonsplitTabNewWorkspaceDropView {
        SidebarBonsplitTabNewWorkspaceDropView()
    }

    func updateNSView(_ view: SidebarBonsplitTabNewWorkspaceDropView, context: Context) {
        view.isValidTransfer = { transfer in
            AppDelegate.shared?.canMoveBonsplitTabToNewWorkspace(tabId: transfer.tab.id) ?? false
        }
        view.setDropActive = { isActive in
            dropIndicator = isActive ? SidebarDropIndicator(tabId: nil, edge: .bottom) : nil
        }
        view.performMove = { transfer in
            guard let app = AppDelegate.shared,
                  let result = app.moveBonsplitTabToNewWorkspace(
                    tabId: transfer.tab.id,
                    destinationManager: tabManager,
                    focus: true,
                    focusWindow: true,
                    placementOverride: .end
                  ) else {
                return false
            }
            selectedTabIds = [result.destinationWorkspaceId]
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex {
                $0.id == result.destinationWorkspaceId
            }
            return true
        }
    }
}

struct MarkdownWebRenderer: NSViewRepresentable {
    typealias Coordinator = MarkdownWebRendererCore.Coordinator
    static let localImageURLScheme = MarkdownWebRendererCore.localImageURLScheme
    static let remoteImageURLScheme = MarkdownWebRendererCore.remoteImageURLScheme

    let markdown: String
    let theme: MarkdownWebTheme
    let backgroundColor: NSColor
    let panelId: UUID
    let workspaceId: UUID
    let filePath: String
    let fontSize: Double
    let fontFamily: String
    let maxContentWidth: Double
    let session: MarkdownRendererSession
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        session.coordinator(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
    }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = context.coordinator.webView {
            webView.removeFromSuperview()
            configure(webView, coordinator: context.coordinator)
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.add(
            WeakMarkdownScriptMessageHandler(context.coordinator),
            name: "cmuxLib"
        )
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: Self.localImageURLScheme)
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: Self.remoteImageURLScheme)
        let webView = MarkdownWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        context.coordinator.webView = webView
        configure(webView, coordinator: context.coordinator)
        context.coordinator.loadShell(theme: theme, initialMarkdown: markdown)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        configure(webView, coordinator: context.coordinator)
        context.coordinator.update(markdown: markdown, theme: theme)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        if coordinator.webView === webView { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxLib")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        (webView as? MarkdownWebView)?.onPointerDown = nil
        (webView as? MarkdownWebView)?.onLeaveWindow = nil
        (webView as? MarkdownWebView)?.onReenterWindow = nil
        coordinator.cancelImageLoads()
    }

    private func configure(_ webView: WKWebView, coordinator: Coordinator) {
        if let markdownView = webView as? MarkdownWebView {
            markdownView.onPointerDown = onRequestPanelFocus
            markdownView.onLeaveWindow = { [weak coordinator] in
                coordinator?.handleViewLeftWindow()
            }
            markdownView.onReenterWindow = { [weak coordinator] in
                coordinator?.handleViewReenteredWindow()
            }
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
        coordinator.setFontSize(fontSize)
        coordinator.setFontFamily(fontFamily)
        coordinator.setMaxContentWidth(maxContentWidth)
    }
}

struct BrowserDesignModeToolbarButton: NSViewRepresentable {
    let controller: BrowserDesignModeController
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let inactiveColor: NSColor
    let onToggle: @MainActor () async -> Bool

    func makeNSView(context: Context) -> BrowserDesignModeToolbarButtonView {
        BrowserDesignModeToolbarButtonView(frame: .zero)
    }

    func updateNSView(_ view: BrowserDesignModeToolbarButtonView, context: Context) {
        view.update(
            controller: controller,
            iconPointSize: iconPointSize,
            hitSize: hitSize,
            inactiveColor: inactiveColor,
            onToggle: onToggle
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: BrowserDesignModeToolbarButtonView,
        context: Context
    ) -> CGSize? {
        CGSize(width: hitSize, height: hitSize)
    }
}

private extension Font.Weight {
    var nsFontWeight: NSFont.Weight {
        if self == .ultraLight { return .ultraLight }
        if self == .thin { return .thin }
        if self == .light { return .light }
        if self == .medium { return .medium }
        if self == .semibold { return .semibold }
        if self == .bold { return .bold }
        if self == .heavy { return .heavy }
        if self == .black { return .black }
        return .regular
    }
}

struct CmuxSystemSymbolImage: View {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent

    let systemName: String
    let pointSize: CGFloat
    var weight: Font.Weight?
    var alignment: Alignment = .center
    var appliesGlobalFontMagnification = false

    init(
        systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center,
        appliesGlobalFontMagnification: Bool = false
    ) {
        self.systemName = systemName
        self.pointSize = pointSize
        self.weight = weight
        self.alignment = alignment
        self.appliesGlobalFontMagnification = appliesGlobalFontMagnification
    }

    init(
        magnified systemName: String,
        pointSize: CGFloat,
        weight: Font.Weight? = nil,
        alignment: Alignment = .center
    ) {
        self.init(
            systemName: systemName,
            pointSize: pointSize,
            weight: weight,
            alignment: alignment,
            appliesGlobalFontMagnification: true
        )
    }

    var body: some View {
        let rasterSize = RenderableSystemSymbol.resolvedRasterPointSize(
            pointSize,
            globalFontPercent: globalFontPercent,
            appliesGlobalFontMagnification: appliesGlobalFontMagnification
        )
        if let image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: systemName,
            pointSize: rasterSize,
            weight: weight.map(\.nsFontWeight)
        ) {
            Image(nsImage: image)
                .renderingMode(.template)
                .frame(width: rasterSize, height: rasterSize, alignment: alignment)
        } else {
            Color.clear
                .frame(width: rasterSize, height: rasterSize, alignment: alignment)
                .accessibilityHidden(true)
        }
    }
}
import WebKit

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

func cmuxAccentColor() -> Color {
    Color(nsColor: cmuxAccentNSColor())
}

extension StoredShortcut {
    var swiftUIKeyEquivalent: KeyEquivalent? {
        keyEquivalent.map { character in
            KeyEquivalent(character)
        }
    }

    var swiftUIEventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if eventModifiers.contains(.command) { result.insert(.command) }
        if eventModifiers.contains(.shift) { result.insert(.shift) }
        if eventModifiers.contains(.option) { result.insert(.option) }
        if eventModifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

/// Transitional width observers used by the legacy root while the sidebar
/// layout itself is already stored with Observation.
struct SidebarWidthReader<Content: View>: View {
    @Bindable var layout: SidebarLayoutModel
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(layout.width)
    }
}

struct SidebarWidthSettlingObserver: View {
    @Bindable var layout: SidebarLayoutModel
    let onSettle: () -> Void

    var body: some View {
        Color.clear
            .onAppear(perform: onSettle)
            .onChange(of: layout.width) { _, _ in onSettle() }
    }
}

struct SidebarWidthFrameModifier: ViewModifier {
    @Bindable var layout: SidebarLayoutModel

    func body(content: Content) -> some View {
        content.frame(width: layout.width)
    }
}

struct SidebarWidthLeadingPaddingModifier: ViewModifier {
    @Bindable var layout: SidebarLayoutModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content.padding(.leading, enabled ? layout.width : 0)
    }
}

/// Transitional mount for the native pointer event host while the root
/// workspace hierarchy is still hosted by the legacy renderer.
@MainActor
struct SidebarPointerEventHost: NSViewRepresentable {
    let onResolve: @MainActor (NSView) -> Void
    let onDismantle: @MainActor (NSView) -> Void

    init(
        _ onResolve: @escaping @MainActor (NSView) -> Void,
        onDismantle: @escaping @MainActor (NSView) -> Void
    ) {
        self.onResolve = onResolve
        self.onDismantle = onDismantle
    }

    func makeNSView(context: Context) -> SidebarPointerEventHostView {
        let view = SidebarPointerEventHostView()
        view.onResolve = onResolve
        view.onDismantle = onDismantle
        return view
    }

    func updateNSView(_ view: SidebarPointerEventHostView, context: Context) {
        view.onResolve = onResolve
        view.onDismantle = onDismantle
        view.resolve()
    }

    static func dismantleNSView(_ view: SidebarPointerEventHostView, coordinator: ()) {
        view.onDismantle?(view)
        view.onResolve = nil
        view.onDismantle = nil
    }
}

@MainActor
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void
    let dedupeByWindow: Bool
    let refreshID: AnyHashable?

    init(
        dedupeByWindow: Bool = true,
        refreshID: AnyHashable? = nil,
        onWindow: @escaping @MainActor (NSWindow) -> Void
    ) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
        self.refreshID = refreshID
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        installWindowHandler(on: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {
        installWindowHandler(on: view, coordinator: context.coordinator)
        if let window = view.window { view.onWindow?(window) }
    }

    private func installWindowHandler(on view: WindowObservingView, coordinator: Coordinator) {
        let handler = onWindow
        let shouldDedupeByWindow = dedupeByWindow
        let refreshID = refreshID
        view.onWindow = { window in
            guard coordinator.shouldInvoke(
                window: window,
                dedupeByWindow: shouldDedupeByWindow,
                refreshID: refreshID
            ) else { return }
            handler(window)
        }
    }

    final class Coordinator {
        private weak var lastWindow: NSWindow?
        private var lastRefreshID: AnyHashable?

        func shouldInvoke(
            window: NSWindow,
            dedupeByWindow: Bool,
            refreshID: AnyHashable?
        ) -> Bool {
            if dedupeByWindow, lastWindow === window, lastRefreshID == refreshID { return false }
            lastWindow = window
            lastRefreshID = refreshID
            return true
        }
    }
}

struct RightSidebarChromeGeometryReporter: NSViewRepresentable {
    var role: RightSidebarChromeGeometryRole
    var isVisible: Bool
    var titlebarHeight: CGFloat

    func makeNSView(context: Context) -> RightSidebarChromeGeometryReportingView {
        let view = RightSidebarChromeGeometryReportingView()
        update(view)
        return view
    }

    func updateNSView(_ view: RightSidebarChromeGeometryReportingView, context: Context) {
        update(view)
        view.reportIfNeeded()
    }

    private func update(_ view: RightSidebarChromeGeometryReportingView) {
        view.role = role
        view.isVisibleForReporting = isVisible
        view.titlebarHeight = titlebarHeight
    }
}

extension View {
    func reportRightSidebarChromeGeometryForBonsplitUITest(
        role: RightSidebarChromeGeometryRole = .modeBar,
        isVisible: Bool,
        titlebarHeight: CGFloat
    ) -> some View {
        background(
            RightSidebarChromeGeometryReporter(
                role: role,
                isVisible: isVisible,
                titlebarHeight: titlebarHeight
            )
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    func reportRightSidebarChromeNamedGeometryForBonsplitUITest(
        keyPrefix: String?,
        isVisible: Bool
    ) -> some View {
        if let keyPrefix {
            background(
                RightSidebarChromeGeometryReporter(
                    role: .named(keyPrefix),
                    isVisible: isVisible,
                    titlebarHeight: 0
                )
                .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}

struct TitlebarChromeGeometryReporter: NSViewRepresentable {
    let keyPrefix: String

    func makeNSView(context: Context) -> TitlebarChromeGeometryReportingView {
        let view = TitlebarChromeGeometryReportingView()
        view.keyPrefix = keyPrefix
        return view
    }

    func updateNSView(_ view: TitlebarChromeGeometryReportingView, context: Context) {
        view.keyPrefix = keyPrefix
        view.reportSoon()
    }
}

struct SidebarWorkspaceScrollEdgeFadeMask: NSViewRepresentable {
    let topHeight: CGFloat
    let bottomHeight: CGFloat

    func makeNSView(context: Context) -> SidebarWorkspaceScrollEdgeFadeMaskView {
        SidebarWorkspaceScrollEdgeFadeMaskView()
    }

    func updateNSView(_ view: SidebarWorkspaceScrollEdgeFadeMaskView, context: Context) {
        view.topHeight = topHeight
        view.bottomHeight = bottomHeight
    }
}

struct SidebarDividerTracker: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> SidebarDividerTrackingView {
        let view = SidebarDividerTrackingView()
        update(view)
        return view
    }

    func updateNSView(_ view: SidebarDividerTrackingView, context: Context) {
        update(view)
    }

    private func update(_ view: SidebarDividerTrackingView) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

struct PaneDropTargetRepresentable: NSViewRepresentable {
    let dropContext: PaneDropContext?

    func makeNSView(context: Context) -> PaneDropTargetView {
        PaneDropTargetView(frame: .zero)
    }

    func updateNSView(_ view: PaneDropTargetView, context: Context) {
        view.dropContext = dropContext
        view.hostedView = nil
        if dropContext == nil { view.draggingExited(nil) }
    }
}

struct FilePreviewTextEditor<PanelModel>: NSViewRepresentable
where PanelModel: ObservableObject & FilePreviewTextEditingPanel {
    @ObservedObject var panel: PanelModel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool
    let wordWrap: Bool

    func makeCoordinator() -> FilePreviewTextEditorController {
        FilePreviewTextEditorController(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            themeBackgroundColor: themeBackgroundColor,
            themeForegroundColor: themeForegroundColor,
            drawsBackground: drawsBackground,
            wordWrap: wordWrap
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.configure(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            themeBackgroundColor: themeBackgroundColor,
            themeForegroundColor: themeForegroundColor,
            drawsBackground: drawsBackground,
            wordWrap: wordWrap
        )
    }
}

struct DetachedFolderDragIcon: NSViewRepresentable {
    let directory: String

    func makeNSView(context: Context) -> DraggableFolderNSView {
        DraggableFolderNSView(directory: directory)
    }

    func updateNSView(_ view: DraggableFolderNSView, context: Context) {
        guard view.directory != directory else { return }
        view.directory = directory
        view.updateIcon()
    }
}

struct MinimalModeSidebarControlActionProxyView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig
    var isEnabled = true
    var requiresRevealedState = false
    let onAction: (MinimalModeSidebarControlActionSlot, NSView, NSPoint) -> Void

    func makeNSView(context: Context) -> MinimalModeSidebarControlActionView {
        let view = MinimalModeSidebarControlActionView()
        configure(view)
        return view
    }

    func updateNSView(_ view: MinimalModeSidebarControlActionView, context: Context) {
        configure(view)
    }

    private func configure(_ view: MinimalModeSidebarControlActionView) {
        view.config = config
        view.isEnabled = isEnabled
        view.requiresRevealedState = requiresRevealedState
        view.onAction = onAction
    }
}

struct TitlebarInteractiveControlRegion: NSViewRepresentable {
    typealias RegisteredView = TitlebarInteractiveControlRegionView

    func makeNSView(context: Context) -> TitlebarInteractiveControlRegionView {
        TitlebarInteractiveControlRegionView(frame: .zero)
    }

    func updateNSView(_ view: TitlebarInteractiveControlRegionView, context: Context) {
        MinimalModeTitlebarControlHitRegionRegistry.register(view)
    }
}

struct WindowDragHandleView: NSViewRepresentable {
    static let viewIdentifier = WindowDragHandleNSView.viewIdentifier
    var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction

    func makeNSView(context: Context) -> WindowDragHandleNSView {
        WindowDragHandleNSView(doubleClickBehavior: doubleClickBehavior)
    }

    func updateNSView(_ view: WindowDragHandleNSView, context: Context) {
        view.doubleClickBehavior = doubleClickBehavior
    }
}

struct TitlebarDoubleClickMonitorView: NSViewRepresentable {
    var doubleClickBehavior: TitlebarDoubleClickBehavior = .standardAction

    func makeNSView(context: Context) -> TitlebarDoubleClickMonitorNSView {
        let view = TitlebarDoubleClickMonitorNSView(frame: .zero)
        view.doubleClickBehavior = doubleClickBehavior
        return view
    }

    func updateNSView(_ view: TitlebarDoubleClickMonitorNSView, context: Context) {
        view.doubleClickBehavior = doubleClickBehavior
    }
}

struct MinimalModeTitlebarEventSurfaceView: NSViewRepresentable {
    var isEnabled: Bool

    func makeNSView(context: Context) -> MinimalModeTitlebarEventSurfaceNSView {
        let view = MinimalModeTitlebarEventSurfaceNSView(frame: .zero)
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: MinimalModeTitlebarEventSurfaceNSView, context: Context) {
        view.isEnabled = isEnabled
    }
}

#if DEBUG
private struct MinimalModeInvalidationProbeKey: EnvironmentKey {
    static let defaultValue = MinimalModeInvalidationProbe()
}

private struct SidebarLazyContractProbeKey: EnvironmentKey {
    static let defaultValue = SidebarLazyContractProbe()
}

extension EnvironmentValues {
    var minimalModeInvalidationProbe: MinimalModeInvalidationProbe {
        get { self[MinimalModeInvalidationProbeKey.self] }
        set { self[MinimalModeInvalidationProbeKey.self] = newValue }
    }

    var sidebarLazyContractProbe: SidebarLazyContractProbe {
        get { self[SidebarLazyContractProbeKey.self] }
        set { self[SidebarLazyContractProbeKey.self] = newValue }
    }
}
#endif

enum SidebarTitleFirstLineCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

extension VerticalAlignment {
    static let sidebarTitleFirstLineCenter = VerticalAlignment(
        SidebarTitleFirstLineCenterAlignment.self
    )
}

extension View {
    @ViewBuilder
    func sidebarRowDragGate(
        isEditing: Bool,
        _ makeProvider: @escaping () -> NSItemProvider
    ) -> some View {
        if isEditing { self } else { onDrag(makeProvider) }
    }
}

struct MinimalModeTitlebarEventSurfaceLayer: View {
    let isFullScreen: Bool
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    var body: some View {
        MinimalModeTitlebarEventSurfaceView(
            isEnabled: WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
                && !isFullScreen
        )
    }
}

struct WorkspaceContentMinimalModeSafeAreaModifier: ViewModifier {
    let isFullScreen: Bool
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    func body(content: Content) -> some View {
        let isMinimal = WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
        content.ignoresSafeArea(.container, edges: (isMinimal && !isFullScreen) ? .top : [])
    }
}

struct WorkspaceTitlebarModeLayer<Titlebar: View>: View {
    let titlebar: () -> Titlebar
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    var body: some View {
        if WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) != .minimal {
            titlebar()
        }
    }
}

private struct CanvasInlineBrowserHostingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cmuxCanvasInlineBrowserHosting: Bool {
        get { self[CanvasInlineBrowserHostingKey.self] }
        set { self[CanvasInlineBrowserHostingKey.self] = newValue }
    }
}

struct TitlebarInteractiveControlModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(TitlebarInteractiveControlRegion())
    }
}

extension View {
    func titlebarInteractiveControl() -> some View {
        modifier(TitlebarInteractiveControlModifier())
    }
}

struct WorkspacePresentationModeContentTopPaddingModifier: ViewModifier {
    let isFullScreen: Bool
    let titlebarPadding: CGFloat
    let hostingSafeAreaTop: CGFloat
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    func body(content: Content) -> some View {
        content.padding(.top, ContentView.effectiveTitlebarPadding(
            isMinimalMode: WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        ))
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
enum InternalTabDragConfigurationProvider {
    static let value = DragConfiguration(
        operationsWithinApp: .init(allowCopy: false, allowMove: true, allowDelete: false),
        operationsOutsideApp: .init(allowCopy: false, allowMove: false, allowDelete: false)
    )
}
#endif

private struct InternalTabDragConfigurationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.dragConfiguration(InternalTabDragConfigurationProvider.value)
        } else {
            content
        }
#else
        content
#endif
    }
}

extension View {
    func internalOnlyTabDrag() -> some View {
        modifier(InternalTabDragConfigurationModifier())
    }
}

/// Transitional mounts for native support views while their parent surfaces
/// are still being moved to AppKit controllers.

private struct CmuxPaneDropZoneEnvironmentKey: EnvironmentKey {
    static let defaultValue: DropZone? = nil
}

extension EnvironmentValues {
    var paneDropZone: DropZone? {
        get { self[CmuxPaneDropZoneEnvironmentKey.self] }
        set { self[CmuxPaneDropZoneEnvironmentKey.self] = newValue }
    }
}

@MainActor
private final class BonsplitSwiftUIProviderBox<Content: View, EmptyContent: View> {
    var content: (Bonsplit.Tab, PaneID) -> Content
    var emptyPane: (PaneID) -> EmptyContent

    init(
        content: @escaping (Bonsplit.Tab, PaneID) -> Content,
        emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.content = content
        self.emptyPane = emptyPane
    }
}

@MainActor
private final class BonsplitSwiftUIContentController: NSHostingController<AnyView>,
    BonsplitContentUpdating,
    BonsplitPaneDropZoneReceiving
{
    private var tab: Bonsplit.Tab?
    private var pane: PaneID?
    private var dropZone: DropZone?
    private let render: @MainActor (Bonsplit.Tab, PaneID, DropZone?) -> AnyView

    init(
        tab: Bonsplit.Tab,
        pane: PaneID,
        render: @escaping @MainActor (Bonsplit.Tab, PaneID, DropZone?) -> AnyView
    ) {
        self.tab = tab
        self.pane = pane
        self.render = render
        super.init(rootView: render(tab, pane, nil))
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateBonsplitContent(tab: Bonsplit.Tab, pane: PaneID) {
        self.tab = tab
        self.pane = pane
        rootView = render(tab, pane, dropZone)
    }

    func bonsplitPaneDropZoneDidChange(_ zone: DropZone?) {
        dropZone = zone
        guard let tab, let pane else { return }
        rootView = render(tab, pane, zone)
    }
}

@MainActor
private final class BonsplitSwiftUIEmptyController: NSHostingController<AnyView> {
    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Temporary SwiftUI mount for Bonsplit's AppKit controller. The split and tab
/// hierarchy is native; only host-supplied cmux content remains hosted here.
struct BonsplitView<Content: View, EmptyContent: View>: NSViewControllerRepresentable {
    let controller: BonsplitController
    let content: (Bonsplit.Tab, PaneID) -> Content
    let emptyPane: (PaneID) -> EmptyContent

    init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Bonsplit.Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.content = content
        self.emptyPane = emptyPane
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, emptyPane: emptyPane)
    }

    func makeNSViewController(context: Context) -> BonsplitViewController {
        context.coordinator.makeViewController(controller: controller)
    }

    func updateNSViewController(_ viewController: BonsplitViewController, context: Context) {
        context.coordinator.providers.content = content
        context.coordinator.providers.emptyPane = emptyPane
        context.coordinator.update(viewController)
    }

    @MainActor
    final class Coordinator {
        let providers: BonsplitSwiftUIProviderBox<Content, EmptyContent>

        init(
            content: @escaping (Bonsplit.Tab, PaneID) -> Content,
            emptyPane: @escaping (PaneID) -> EmptyContent
        ) {
            providers = BonsplitSwiftUIProviderBox(content: content, emptyPane: emptyPane)
        }

        func makeViewController(controller: BonsplitController) -> BonsplitViewController {
            BonsplitViewController(
                controller: controller,
                content: contentProvider(),
                emptyPane: emptyProvider()
            )
        }

        func update(_ viewController: BonsplitViewController) {
            viewController.updateProviders(
                content: contentProvider(),
                emptyPane: emptyProvider()
            )
        }

        private func contentProvider() -> BonsplitViewController.ContentProvider {
            { [weak providers] tab, pane in
                BonsplitSwiftUIContentController(tab: tab, pane: pane) { [weak providers] tab, pane, zone in
                    guard let providers else { return AnyView(EmptyView()) }
                    return AnyView(providers.content(tab, pane).environment(\.paneDropZone, zone))
                }
            }
        }

        private func emptyProvider() -> BonsplitViewController.EmptyPaneProvider {
            { [weak providers] pane in
                guard let providers else {
                    return BonsplitSwiftUIEmptyController(rootView: AnyView(EmptyView()))
                }
                return BonsplitSwiftUIEmptyController(rootView: AnyView(providers.emptyPane(pane)))
            }
        }
    }
}

extension WindowChromeColorScheme {
    var transitionalColorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

extension ColorScheme {
    var nativeWindowChromeColorScheme: WindowChromeColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        @unknown default: .dark
        }
    }
}

/// Keeps transitional SwiftUI roots synchronized with the native appearance
/// source of truth while those roots are being removed.
private struct AppearanceColorSchemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemAppearanceGeneration = 0
    let rawValue: String?

    func body(content: Content) -> some View {
        let override = AppearanceSettings.colorSchemeOverride(for: rawValue)
        let _ = systemAppearanceGeneration
        let effective = AppearanceSettings.effectiveColorScheme(
            for: rawValue,
            fallback: colorScheme.nativeWindowChromeColorScheme
        )
        content
            .environment(\.colorScheme, effective.transitionalColorScheme)
            .preferredColorScheme(override?.transitionalColorScheme)
            .onReceive(NotificationCenter.default.publisher(for: .systemAppearanceDidChange)) { _ in
                systemAppearanceGeneration &+= 1
            }
    }
}

extension View {
    func cmuxAppearanceColorScheme(_ rawValue: String?) -> some View {
        modifier(AppearanceColorSchemeModifier(rawValue: rawValue))
    }
}

struct NativeWindowBackdropLayer: NSViewRepresentable {
    let role: WindowBackdropRole
    let snapshot: WindowAppearanceSnapshot

    func makeNSView(context: Context) -> WindowBackdropLayer {
        WindowBackdropLayer(role: role, snapshot: snapshot)
    }

    func updateNSView(_ view: WindowBackdropLayer, context: Context) {
        view.update(role: role, snapshot: snapshot)
    }
}

struct NativeWindowChromeBorder: NSViewRepresentable {
    let orientation: WindowChromeBorderOrientation
    var ignoresSafeArea = true
    var refreshNotificationName: Notification.Name?
    let backgroundColorProvider: @MainActor () -> NSColor

    func makeNSView(context: Context) -> WindowChromeBorder {
        WindowChromeBorder(
            orientation: orientation,
            ignoresSafeArea: ignoresSafeArea,
            refreshNotificationName: refreshNotificationName,
            backgroundColorProvider: backgroundColorProvider
        )
    }

    func updateNSView(_ view: WindowChromeBorder, context: Context) {
        view.refresh()
    }
}

struct NativeResolvedIconImage: NSViewRepresentable {
    let request: CmuxResolvedIconRequest?

    func makeNSView(context: Context) -> CmuxResolvedIconImage {
        CmuxResolvedIconImage(request: request)
    }

    func updateNSView(_ view: CmuxResolvedIconImage, context: Context) {
        view.apply(request)
    }
}

struct NativeAccountSignInViewBridge: NSViewRepresentable {
    let model: AccountSignInModel
    let automaticallyStartsSignIn: Bool

    func makeNSView(context: Context) -> AccountSignInView {
        AccountSignInView(
            model: model,
            automaticallyStartsSignIn: automaticallyStartsSignIn
        )
    }

    func updateNSView(_ view: AccountSignInView, context: Context) {}
}

struct NativeStackAccountAvatarBridge: NSViewRepresentable {
    let avatarURL: URL?
    let displayName: String
    let email: String
    let size: CGFloat
    let loadingSystemName: String?

    func makeNSView(context: Context) -> StackAccountAvatarView {
        StackAccountAvatarView(
            avatarURL: avatarURL,
            displayName: displayName,
            email: email,
            size: size,
            loadingSystemName: loadingSystemName
        )
    }

    func updateNSView(_ view: StackAccountAvatarView, context: Context) {
        view.update(avatarURL: avatarURL, displayName: displayName, email: email)
    }
}

struct NativeMobilePairingViewBridge: NSViewRepresentable {
    let backgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> MobilePairingView {
        MobilePairingView(
            backgroundColor: backgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }

    func updateNSView(_ view: MobilePairingView, context: Context) {
        view.updatePresentation(
            backgroundColor: backgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
}

struct MobilePairingPanelView: View {
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        NativeMobilePairingViewBridge(
            backgroundColor: appearance.contentBackgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
        .accessibilityIdentifier("MobilePairingPanel")
    }
}

struct AccountSignInPanelView: View {
    let panel: AccountSignInPanel
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ScrollView {
            NativeAccountSignInViewBridge(model: panel.model, automaticallyStartsSignIn: true)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
        .accessibilityIdentifier("AccountSignInPanel")
    }
}

struct SidebarProBadge: View {
    var body: some View { NativeProBadgeViewBridge() }
}

struct SimulatorPanelView: NSViewControllerRepresentable {
    let panel: SimulatorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let allowsPointerInput: Bool
    let pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> SimulatorPanelLifecycleHost {
        SimulatorPanelLifecycleHost()
    }

    func makeNSViewController(context: Context) -> SimulatorPaneView {
        let controller = SimulatorPaneView(
            coordinator: panel.coordinator,
            backgroundColor: appearance.contentBackgroundColor,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            onRequestPanelFocus: onRequestPanelFocus
        )
        context.coordinator.installFocusOwnershipView(in: controller)
        update(controller, lifecycle: context.coordinator)
        return controller
    }

    func updateNSViewController(_ controller: SimulatorPaneView, context: Context) {
        update(controller, lifecycle: context.coordinator)
    }

    static func dismantleNSViewController(
        _ controller: SimulatorPaneView,
        coordinator: SimulatorPanelLifecycleHost
    ) {
        coordinator.teardown(controller: controller)
    }

    private func update(
        _ controller: SimulatorPaneView,
        lifecycle: SimulatorPanelLifecycleHost
    ) {
        lifecycle.update(
            controller: controller,
            panel: panel,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: allowsPointerInput,
            pointerEntryEventFilter: pointerEntryEventFilter,
            backgroundColor: appearance.contentBackgroundColor,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }
}

struct NotificationPopoverRow: NSViewRepresentable, Equatable {
    nonisolated static func == (lhs: NotificationPopoverRow, rhs: NotificationPopoverRow) -> Bool {
        lhs.notification == rhs.notification && lhs.workspaceTitle == rhs.workspaceTitle
    }

    let notification: TerminalNotification
    let workspaceTitle: String?
    let onOpen: () -> Void
    let onClear: () -> Void
    let onToggleRead: () -> Void

    func makeNSView(context: Context) -> NotificationPopoverRowNativeView {
        NotificationPopoverRowNativeView(frame: .zero)
    }

    func updateNSView(_ view: NotificationPopoverRowNativeView, context: Context) {
        view.update(
            notification: notification,
            workspaceTitle: workspaceTitle,
            onOpen: onOpen,
            onClear: onClear,
            onToggleRead: onToggleRead
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NotificationPopoverRowNativeView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? max(1, nsView.bounds.width),
            height: nsView.intrinsicContentSize.height
        )
    }
}

struct ResizeGripperRepresentable: NSViewRepresentable {
    let onBegin: () -> (CGFloat, CGFloat)
    let onDrag: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> ResizeGripperNSView {
        ResizeGripperNSView()
    }

    func updateNSView(_ view: ResizeGripperNSView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

struct GPUSpinner: NSViewRepresentable {
    let style: GPUSpinnerStyle
    let color: NSColor

    func makeNSView(context: Context) -> GPUSpinnerNSView {
        let view = GPUSpinnerNSView(frame: .zero)
        view.style = style
        view.color = color
        return view
    }

    func updateNSView(_ view: GPUSpinnerNSView, context: Context) {
        view.style = style
        view.color = color
    }
}

struct FilePreviewImageView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewImageContainerView {
        panel.nativeViewSessions.image.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: FilePreviewImageContainerView, context: Context) {
        panel.nativeViewSessions.image.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

struct FilePreviewPDFView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewPDFContainerView {
        panel.nativeViewSessions.pdf.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: FilePreviewPDFContainerView, context: Context) {
        panel.nativeViewSessions.pdf.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

struct FilePreviewMediaView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        panel.nativeViewSessions.media.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        panel.nativeViewSessions.media.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

struct SessionIndexTableView: NSViewRepresentable {
    let rows: [SessionIndexTableRow]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontMagnificationPercent

    func makeCoordinator() -> SessionIndexTableController { SessionIndexTableController() }

    func makeNSView(context: Context) -> SessionIndexTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ view: SessionIndexTableContainerView, context: Context) {
        context.coordinator.apply(
            rows: rows,
            environment: SessionIndexTableEnvironmentSnapshot(
                colorScheme: colorScheme == .dark ? .dark : .light,
                globalFontMagnificationPercent: globalFontMagnificationPercent
            )
        )
    }

    static func dismantleNSView(
        _ view: SessionIndexTableContainerView,
        coordinator: SessionIndexTableController
    ) {
        coordinator.dismantle()
    }
}

struct NativeFeedbackComposerBridge: NSViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    func makeNSViewController(context: Context) -> SidebarFeedbackComposerSheet {
        let coordinator = context.coordinator
        return SidebarFeedbackComposerSheet { coordinator.dismiss() }
    }

    func updateNSViewController(
        _ viewController: SidebarFeedbackComposerSheet,
        context: Context
    ) {
        context.coordinator.dismissAction = dismiss
    }

    @MainActor
    final class Coordinator {
        var dismissAction: DismissAction
        init(dismiss: DismissAction) { dismissAction = dismiss }
        func dismiss() { dismissAction() }
    }
}

struct NativeCustomSidebarSurfaceBridge: NSViewRepresentable {
    let fileURL: URL
    let dataContext: [String: SwiftValue]
    let dispatch: SidebarActionDispatch
    let contentInsets: CustomSidebarContentInsets
    let rendersInProcess: Bool
    let clientStore: RenderWorkerClientStore

    func makeNSView(context: Context) -> CustomSidebarSurface {
        CustomSidebarSurface(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            rendersInProcess: rendersInProcess,
            clientStore: clientStore
        )
    }

    func updateNSView(_ view: CustomSidebarSurface, context: Context) {
        view.update(
            fileURL: fileURL,
            dataContext: dataContext,
            dispatch: dispatch,
            contentInsets: contentInsets,
            rendersInProcess: rendersInProcess
        )
    }

    static func dismantleNSView(_ view: CustomSidebarSurface, coordinator: ()) {
        view.teardown()
    }
}

struct SidebarWorkspaceTableView: NSViewRepresentable {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    let isPresented: Bool
    let unreadSource: SidebarUnreadModel

#if DEBUG
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    func makeCoordinator() -> SidebarWorkspaceTableController { SidebarWorkspaceTableController() }

    func makeNSView(context: Context) -> SidebarWorkspaceTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ view: SidebarWorkspaceTableContainerView, context: Context) {
#if DEBUG
        context.coordinator.reconfigurationProbe = sidebarLazyContractProbe.tableRootViewReconfigure
#endif
        context.coordinator.setUnreadSource(unreadSource)
        context.coordinator.setPresentationActive(isPresented, workspaceIds: workspaceIds)
        guard isPresented else { return }
        context.coordinator.apply(
            rows: rows,
            actions: actions,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId
        )
    }

    static func dismantleNSView(
        _ view: SidebarWorkspaceTableContainerView,
        coordinator: SidebarWorkspaceTableController
    ) {
        coordinator.dismantleContainerView(view)
    }
}

struct QuickLookPreviewView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeCoordinator() -> FilePreviewQuickLookViewCoordinator {
        FilePreviewQuickLookViewCoordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSView {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        return quickLook.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ view: NSView, context: Context) {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        quickLook.update(
            view,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    static func dismantleNSView(_ view: NSView, coordinator: FilePreviewQuickLookViewCoordinator) {
        coordinator.quickLook?.dismantle(view)
        coordinator.quickLook = nil
    }
}

private struct AgentSessionPanelNativeBridge: NSViewRepresentable {
    let panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let theme: AgentSessionWebTheme
    let sessionContentWidthPresentation: SessionContentWidthPresentation
    let onRequestPanelFocus: () -> Void

    func makeNSView(context: Context) -> AgentSessionPanelNativeView {
        AgentSessionPanelNativeView(frame: .zero)
    }

    func updateNSView(_ view: AgentSessionPanelNativeView, context: Context) {
        view.update(
            panel: panel,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            theme: theme,
            sessionContentWidthPresentation: sessionContentWidthPresentation,
            onRequestPanelFocus: onRequestPanelFocus
        )
    }

    static func dismantleNSView(_ view: AgentSessionPanelNativeView, coordinator: ()) {
        view.teardown()
    }
}

struct AgentSessionPanelView: View {
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedSessionContentMaximumWidth = SessionContentWidthSettings.noMaximumWidth
    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedSessionContentAlignment = SessionContentAlignment.center.rawValue
    let panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        AgentSessionPanelNativeBridge(
            panel: panel,
            isFocused: isFocused,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: appearance.contentBackgroundColor,
            theme: AgentSessionWebTheme.resolve(appearance: appearance),
            sessionContentWidthPresentation: SessionContentWidthPresentation(
                storedMaximumWidth: storedSessionContentMaximumWidth,
                storedAlignment: storedSessionContentAlignment
            ),
            onRequestPanelFocus: onRequestPanelFocus
        )
        .id(panel.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(Double(portalPriority))
    }
}

@MainActor
struct BrowserOmnibarInteractionRepresentable: NSViewRepresentable {
    let panelId: UUID

    func makeNSView(context: Context) -> BrowserOmnibarInteractionView {
        let view = BrowserOmnibarInteractionView(frame: .zero)
        view.panelId = panelId
        return view
    }

    func updateNSView(_ view: BrowserOmnibarInteractionView, context: Context) {
        view.panelId = panelId
        view.window?.invalidateCursorRects(for: view)
    }
}

extension GhosttyTerminalView {
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSView,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? max(1, nsView.bounds.width),
            height: proposal.height ?? max(1, nsView.bounds.height)
        )
    }
}

struct SidebarAgentActivityIndicator: View {
    let spinnerColor: NSColor
    let side: CGFloat

    var body: some View {
        GPUSpinner(style: .macOSSpokes, color: spinnerColor)
            .frame(width: side, height: side)
            .fixedSize()
    }
}

struct SidebarWorkspaceLoadingSpinner: View {
    let side: CGFloat
    let color: NSColor
    let tooltip: String

    var body: some View {
        SidebarAgentActivityIndicator(spinnerColor: color, side: side)
            .safeHelp(tooltip)
            .accessibilityLabel(Text(tooltip))
    }
}

struct WorkspaceAttentionFlashRingView: NSViewRepresentable {
    let opacity: Double
    var reason: WorkspaceAttentionFlashReason = .navigation

    func makeNSView(context: Context) -> WorkspaceAttentionFlashRingNativeView {
        let view = WorkspaceAttentionFlashRingNativeView(frame: .zero)
        view.update(opacity: opacity, reason: reason)
        return view
    }

    func updateNSView(_ view: WorkspaceAttentionFlashRingNativeView, context: Context) {
        view.update(opacity: opacity, reason: reason)
    }
}

struct SimulatorFeatureDisabledView: NSViewRepresentable {
    let panel: SimulatorPanel
    let appearance: PanelAppearance

    func makeNSView(context: Context) -> SimulatorFeatureDisabledNativeView {
        _ = panel
        return SimulatorFeatureDisabledNativeView(
            backgroundColor: appearance.contentBackgroundColor
        )
    }

    func updateNSView(_ view: SimulatorFeatureDisabledNativeView, context: Context) {
        _ = panel
        view.update(backgroundColor: appearance.contentBackgroundColor)
    }
}

struct DockUnreadProjectionContextBridge: NSViewRepresentable {
    let projection: DockUnreadPanelProjection
    let panelIDs: Set<UUID>
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        projection.updateContext(panelIDs: panelIDs, isActive: isActive)
        return NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        projection.updateContext(panelIDs: panelIDs, isActive: isActive)
    }
}

struct WorkspacePresentationModeChangeObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WorkspacePresentationModeObserverView {
        WorkspacePresentationModeObserverView(onChange: onChange)
    }

    func updateNSView(_ view: WorkspacePresentationModeObserverView, context: Context) {
        view.onChange = onChange
        view.publishIfChanged()
    }
}

struct NativeSidebarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    init(_ onResolve: @escaping (NSScrollView?) -> Void) {
        self.onResolve = onResolve
    }

    func makeNSView(context: Context) -> SidebarScrollViewResolver {
        SidebarScrollViewResolver(onResolve: onResolve)
    }

    func updateNSView(_ view: SidebarScrollViewResolver, context: Context) {
        view.onResolve = onResolve
        view.resolveScrollView()
    }
}

struct NativeScrollBackgroundClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollBackgroundClearer {
        ScrollBackgroundClearer(frame: .zero)
    }

    func updateNSView(_ view: ScrollBackgroundClearer, context: Context) {}
}

struct NativeBrowserSearchOverlayBridge: NSViewRepresentable {
    let panelId: UUID
    let searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void

    func makeNSView(context: Context) -> BrowserSearchOverlay {
        BrowserSearchOverlay(
            panelId: panelId,
            searchState: searchState,
            focusRequestGeneration: focusRequestGeneration,
            canApplyFocusRequest: canApplyFocusRequest,
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose,
            onFieldDidFocus: onFieldDidFocus
        )
    }

    func updateNSView(_ view: BrowserSearchOverlay, context: Context) {
        view.update(
            panelId: panelId,
            searchState: searchState,
            focusRequestGeneration: focusRequestGeneration,
            canApplyFocusRequest: canApplyFocusRequest,
            onNext: onNext,
            onPrevious: onPrevious,
            onClose: onClose,
            onFieldDidFocus: onFieldDidFocus
        )
    }
}

struct NativeOmnibarSuggestionsBridge: NSViewRepresentable {
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let colorScheme: WindowChromeColorScheme
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void

    func makeNSView(context: Context) -> OmnibarSuggestionsView {
        OmnibarSuggestionsView(
            engineName: engineName,
            items: items,
            selectedIndex: selectedIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: searchSuggestionsEnabled,
            colorScheme: colorScheme,
            onCommit: onCommit,
            onHighlight: onHighlight
        )
    }

    func updateNSView(_ view: OmnibarSuggestionsView, context: Context) {
        view.update(
            engineName: engineName,
            items: items,
            selectedIndex: selectedIndex,
            isLoadingRemoteSuggestions: isLoadingRemoteSuggestions,
            searchSuggestionsEnabled: searchSuggestionsEnabled,
            colorScheme: colorScheme,
            onCommit: onCommit,
            onHighlight: onHighlight
        )
    }
}

struct NativeProBadgeViewBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> ProBadgeView {
        ProBadgeView(frame: .zero)
    }

    func updateNSView(_ view: ProBadgeView, context: Context) {}

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ProBadgeView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct NativeProBadgeLabelBridge: NSViewRepresentable {
    let style: ProBadgeStyle

    func makeNSView(context: Context) -> ProBadgeLabelView {
        ProBadgeLabelView(style: style)
    }

    func updateNSView(_ view: ProBadgeLabelView, context: Context) {
        view.update(style: style)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ProBadgeLabelView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

@available(macOS 14.0, *)
struct NativeSidebarExtensionHostBridge: NSViewControllerRepresentable {
    let identity: AppExtensionIdentity
    let presentation: CmuxSidebarPresentation?
    var onConnection: (@MainActor (NSXPCConnection) -> Void)?
    var onDeactivation: (@MainActor ((any Error)?) -> Void)?
    var onTeardown: (@MainActor () -> Void)?
    var onPresentationAction: (@MainActor (String) -> Void)?

    func makeNSViewController(context: Context) -> CMUXSidebarExtensionHostView {
        CMUXSidebarExtensionHostView(
            identity: identity,
            presentation: presentation,
            onConnection: onConnection,
            onDeactivation: onDeactivation,
            onTeardown: onTeardown,
            onPresentationAction: onPresentationAction
        )
    }

    func updateNSViewController(
        _ viewController: CMUXSidebarExtensionHostView,
        context: Context
    ) {
        viewController.update(
            identity: identity,
            presentation: presentation,
            onConnection: onConnection,
            onDeactivation: onDeactivation,
            onTeardown: onTeardown,
            onPresentationAction: onPresentationAction
        )
    }

    static func dismantleNSViewController(
        _ viewController: CMUXSidebarExtensionHostView,
        coordinator: ()
    ) {
        viewController.teardown()
    }
}

struct NativeTitlebarLeadingInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat
    let baseLeadingInset: @MainActor () -> CGFloat

    func makeNSView(context: Context) -> TitlebarLeadingInsetReader {
        TitlebarLeadingInsetReader(
            baseLeadingInset: baseLeadingInset,
            onInsetChange: { inset = $0 }
        )
    }

    func updateNSView(_ view: TitlebarLeadingInsetReader, context: Context) {
        view.baseLeadingInset = baseLeadingInset
        view.onInsetChange = { inset = $0 }
        view.resolveInset()
    }
}

struct NativeArrowlessPopoverAnchor<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let detachedGap: CGFloat
    @ViewBuilder let content: () -> PopoverContent

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> ArrowlessPopoverAnchor {
        let coordinator = context.coordinator
        coordinator.updateRootView(AnyView(content()))
        return ArrowlessPopoverAnchor(
            isPresented: isPresented,
            preferredEdge: preferredEdge,
            detachedGap: detachedGap,
            contentViewController: coordinator.hostingController,
            onPresentationChange: { coordinator.isPresented.wrappedValue = $0 }
        )
    }

    func updateNSView(_ view: ArrowlessPopoverAnchor, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        let rootView = AnyView(content())
        if view.isPopoverShown {
            coordinator.visibleUpdateScheduler.schedule { [weak view, weak coordinator] in
                guard let view, let coordinator else { return }
                coordinator.updateRootView(rootView)
                view.update(
                    isPresented: coordinator.isPresented.wrappedValue,
                    preferredEdge: preferredEdge,
                    detachedGap: detachedGap,
                    contentViewController: coordinator.hostingController
                )
            }
        } else {
            coordinator.visibleUpdateScheduler.cancel()
            if isPresented { coordinator.updateRootView(rootView) }
        }
        view.update(
            isPresented: isPresented,
            preferredEdge: preferredEdge,
            detachedGap: detachedGap,
            contentViewController: coordinator.hostingController
        )
    }

    static func dismantleNSView(_ view: ArrowlessPopoverAnchor, coordinator: Coordinator) {
        coordinator.visibleUpdateScheduler.cancel()
        view.dismiss()
    }

    @MainActor
    final class Coordinator {
        var isPresented: Binding<Bool>
        let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        let visibleUpdateScheduler = CmuxPopoverVisibleUpdateScheduler()

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func updateRootView(_ rootView: AnyView) {
            CmuxPopoverMutation.performWithoutImplicitAnimation {
                hostingController.rootView = AnyView(rootView.fixedSize())
                hostingController.view.invalidateIntrinsicContentSize()
                hostingController.view.layoutSubtreeIfNeeded()
            }
        }
    }
}
