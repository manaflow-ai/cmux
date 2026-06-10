import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Extension and custom sidebar data, actions, timeline
extension VerticalTabsSidebar {
    // The provider to actually render. Built-in views are always honored; only
    // the hosted-extension selection falls back to the default workspaces
    // sidebar while the experimental Extensions feature is disabled, since
    // turning extensions off hides that entry and would otherwise strand the
    // user with no way back. Deriving the effective provider (rather than
    // mutating the persisted selection via an observer) routes correctly on the
    // first render pass and restores the user's choice if extensions are
    // re-enabled. Reading `extensionsExperimentalEnabled` here keeps the view
    // reactive to the flag toggling.
    var effectiveExtensionSidebarProviderId: String {
        let selected = selectedExtensionSidebarProviderId
        if selected.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix) {
            // Touch the @LiveSetting so toggling the flag in Settings still
            // re-renders, but decide with the synchronous UserDefaults read:
            // on a sidebar remount @LiveSetting's initial value lags one tick,
            // which would otherwise flash the default sidebar for a frame
            // before swapping to the custom one.
            _ = customSidebarsExperimentalEnabled
            return CmuxExtensionSidebarSelection.customSidebarsEnabled
                ? selected
                : CmuxExtensionSidebarSelection.defaultProviderId
        }
        return CmuxExtensionSidebarSelection.effectiveProviderId(
            selectedExtensionSidebarProviderId,
            extensionsEnabled: extensionsExperimentalEnabled
        )
    }

    /// Live, read-only projection of workspace state handed to custom
    /// sidebars so interpreted Swift can bind to it (e.g.
    /// `ForEach(workspaces) { w in Text(w.title) }`) and re-render when it
    /// changes. A value snapshot built fresh each render, never the store
    /// itself, so it respects the sidebar snapshot-boundary rule.
    private func customSidebarDataContext(now: Date) -> [String: SwiftValue] {
        let selectedId = tabManager.selectedTabId
        let workspaces: [SwiftValue] = tabManager.tabs.enumerated().map { index, workspace in
            customSidebarWorkspaceValue(workspace, index: index, selectedId: selectedId)
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .weekday], from: now)
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0
        let clock: SwiftValue = .object([
            "time": .string(String(format: "%02d:%02d:%02d", hour, minute, second)),
            "hour": .int(hour),
            "minute": .int(minute),
            "second": .int(second),
            "weekday": .int(c.weekday ?? 0),
            "epoch": .int(Int(now.timeIntervalSince1970)),
        ])
        return [
            "workspaces": .array(workspaces),
            "workspaceCount": .int(tabManager.tabs.count),
            "selectedTitle": .string(selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? ""),
            "selectedId": .string(selectedId?.uuidString ?? ""),
            "unreadTotal": .int(notificationStore.unreadCount),
            "clock": clock,
        ]
    }

    /// Projects one workspace's live state into the interpreter value tree.
    /// Optional fields are omitted when absent so interpreted `if let` / ternary
    /// truthiness behaves; always-present fields default sensibly. Keep this in
    /// sync with the data keys documented in `docs/custom-sidebars.md`.
    private func customSidebarWorkspaceValue(_ workspace: Workspace, index: Int, selectedId: UUID?) -> SwiftValue {
        let focusedPanelId = workspace.focusedPanelId
        var fields: [String: SwiftValue] = [
            "id": .string(workspace.id.uuidString),
            "title": .string(workspace.customTitle ?? workspace.title),
            "selected": .bool(workspace.id == selectedId),
            "pinned": .bool(workspace.isPinned),
            "index": .int(index),
            "directory": .string(workspace.currentDirectory),
            "ports": .array(workspace.listeningPorts.map { .int($0) }),
            "portCount": .int(workspace.listeningPorts.count),
            "unread": .int(notificationStore.unreadCount(forTabId: workspace.id)),
            "tabs": .array(customSidebarSurfaceValues(workspace, focusedPanelId: focusedPanelId)),
            "tabCount": .int(workspace.bonsplitController.allPaneIds.reduce(0) { $0 + workspace.bonsplitController.tabs(inPane: $1).count }),
        ]
        if let description = workspace.customDescription, !description.isEmpty { fields["description"] = .string(description) }
        if let color = workspace.customColor, !color.isEmpty { fields["color"] = .string(color) }
        if let git = workspace.gitBranch {
            fields["branch"] = .string(git.branch)
            fields["dirty"] = .bool(git.isDirty)
        }
        if let pr = workspace.pullRequest {
            var prFields: [String: SwiftValue] = [
                "number": .int(pr.number),
                "label": .string(pr.label),
                "url": .string(pr.url.absoluteString),
                "status": .string(pr.status.rawValue),
                "stale": .bool(pr.isStale),
            ]
            if let prBranch = pr.branch { prFields["branch"] = .string(prBranch) }
            fields["pr"] = .object(prFields)
        }
        if let progress = workspace.progress {
            var progressFields: [String: SwiftValue] = ["value": .double(progress.value)]
            if let label = progress.label { progressFields["label"] = .string(label) }
            fields["progress"] = .object(progressFields)
        }
        if let message = workspace.latestConversationMessage, !message.isEmpty { fields["latestMessage"] = .string(message) }
        if let prompt = workspace.latestSubmittedMessage, !prompt.isEmpty { fields["latestPrompt"] = .string(prompt) }
        if let at = workspace.latestSubmittedAt { fields["latestAt"] = .int(Int(at.timeIntervalSince1970)) }
        if let target = workspace.remoteDisplayTarget {
            fields["remote"] = .object([
                "target": .string(target),
                "state": .string(workspace.remoteConnectionState.rawValue),
                "connected": .bool(workspace.remoteConnectionState == .connected),
            ])
        }
        return .object(fields)
    }

    /// Projects a workspace's surfaces (terminal/browser/etc. tabs) into the
    /// interpreter value tree, enriched with per-surface directory, pin, git,
    /// and ports where available.
    private func customSidebarSurfaceValues(_ workspace: Workspace, focusedPanelId: UUID?) -> [SwiftValue] {
        var tabs: [SwiftValue] = []
        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                var surfaceFields: [String: SwiftValue] = [
                    "id": .string(panelId.uuidString),
                    "title": .string(tab.title),
                    "focused": .bool(panelId == focusedPanelId),
                    "pinned": .bool(workspace.pinnedPanelIds.contains(panelId)),
                ]
                if let directory = workspace.panelDirectories[panelId], !directory.isEmpty {
                    surfaceFields["directory"] = .string(directory)
                }
                if let git = workspace.panelGitBranches[panelId] {
                    surfaceFields["branch"] = .string(git.branch)
                    surfaceFields["dirty"] = .bool(git.isDirty)
                }
                if let ports = workspace.surfaceListeningPorts[panelId], !ports.isEmpty {
                    surfaceFields["ports"] = .array(ports.map { .int($0) })
                }
                tabs.append(.object(surfaceFields))
            }
        }
        return tabs
    }
    private static let extensionSidebarObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)
    static let extensionSidebarDisclosureAnimation = Animation.easeInOut(duration: 0.18)
    @ViewBuilder
    func extensionSidebarScrollArea(renderContext: WorkspaceListRenderContext) -> some View {
        if effectiveExtensionSidebarProviderId == CmuxExtensionSidebarSelection.hostedExtensionsProviderId {
            CMUXInstalledExtensionSidebarHostView(
                snapshotProvider: { cmuxSidebarSnapshotForCurrentTabs() },
                snapshotUpdateToken: extensionSidebarUpdateToken,
                actionHandler: { handleCMUXSidebarExtensionAction($0) },
                onUseDefaultSidebar: {
                    CmuxExtensionSidebarSelection.setProviderId(CmuxSidebarProviderDescriptor.defaultWorkspacesID)
                }
            )
            .onReceive(
                extensionSidebarImmediateObservationPublisher(renderContext: renderContext)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                extensionSidebarDebouncedObservationPublisher(renderContext: renderContext)
                    .receive(on: RunLoop.main)
                    .debounce(for: Self.extensionSidebarObservationCoalesceInterval, scheduler: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            // Fade the extension's content out at the bottom so it dissolves behind the
            // sidebar footer instead of overlapping it sharply, matching the default
            // workspace sidebar's bottom scrim. Top stays sharp so the control strip
            // remains crisp.
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: 0,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else if effectiveExtensionSidebarProviderId.hasPrefix(CmuxExtensionSidebarSelection.customSidebarProviderPrefix),
                  let customSidebarURL = CmuxExtensionSidebarSelection.customSidebarFileURL(forProviderId: effectiveExtensionSidebarProviderId) {
            // Periodic tick so the custom sidebar re-renders live (clock,
            // countdowns, and refreshed workspace/data context), mirroring the
            // default sidebar's TimelineView. No banned timers involved.
            // Fully out-of-process: the render worker interprets AND renders
            // the file; this view only hosts the worker's remote layer and
            // forwards input, so no file-derived view code runs in the host.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                // No .id(customSidebarURL): the worker swaps files in place on
                // the next scene message, so remounting the surface would only
                // flash the previous sidebar's pixels during the switch.
                RemoteCustomSidebarHost(
                    fileURL: customSidebarURL,
                    dataContext: customSidebarDataContext(now: timeline.date),
                    dispatch: makeCmuxSidebarActionDispatch(),
                    contentInsets: CustomSidebarContentInsets(
                        top: SidebarWorkspaceScrollInsets.workspaceList.top,
                        bottom: SidebarWorkspaceScrollInsets.workspaceList.bottom
                    )
                )
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let model = extensionSidebarRenderModel(renderContext: renderContext, now: timeline.date)
                extensionSidebarTimelineContent(renderContext: renderContext, model: model, now: timeline.date)
            }
        }
    }

    private func extensionSidebarTimelineContent(
        renderContext: WorkspaceListRenderContext,
        model: CmuxSidebarProviderRenderModel,
        now: Date
    ) -> some View {
        GeometryReader { geometryProxy in
            ScrollView {
                if model.presentation == .browserStack {
                    extensionBrowserStackSidebar(model: model, now: now)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                                viewportHeight: geometryProxy.size.height,
                                insets: SidebarWorkspaceScrollInsets.workspaceList
                            ),
                            alignment: .topLeading
                        )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sections) { section in
                            extensionSidebarSection(section, providerId: model.providerId, now: now)
                        }

                        SidebarEmptyArea(
                            rowSpacing: tabRowSpacing,
                            selection: $selection,
                            selectedTabIds: $selectedTabIds,
                            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                            dragAutoScrollController: dragAutoScrollController,
                            topDropIndicatorVisible: emptyAreaTopDropIndicatorVisible(),
                            tabDropDelegate: emptyAreaTabDropDelegate(),
                            bonsplitDropIndicator: dropIndicatorBinding
                        )
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .padding(.top, SidebarWorkspaceListMetrics.rowVerticalPadding)
                    .padding(.bottom, SidebarWorkspaceListMetrics.rowVerticalPadding + 40)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SidebarWorkspaceScrollLayout.contentMinHeight(
                            viewportHeight: geometryProxy.size.height,
                            insets: SidebarWorkspaceScrollInsets.workspaceList
                        ),
                        alignment: .topLeading
                    )
                }
            }
            .background(
                SidebarScrollViewResolver { scrollView in
                    dragAutoScrollController.attach(scrollView: scrollView)
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.top)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SidebarWorkspaceScrollInsets.workspaceList.bottom)
                    .allowsHitTesting(false)
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: sidebarTopScrimHeight,
                    bottomHeight: sidebarBottomScrimHeight
                )
            )
            .overlay(alignment: .top) {
                WindowDragHandleView()
                    .frame(height: sidebarTitlebarInteractionHeight)
                    .background(TitlebarDoubleClickMonitorView())
            }
            .overlay(alignment: .topLeading) {
                if isMinimalMode {
                    HiddenTitlebarSidebarControlsView(
                        notificationStore: notificationStore,
                        onToggleSidebar: onToggleSidebar,
                        onToggleNotifications: { anchorView in
                            AppDelegate.shared?.toggleNotificationsPopover(
                                animated: true,
                                anchorView: anchorView
                            )
                        },
                        onNewTab: onNewTab,
                        onFocusHistoryBack: {
                            if !tabManager.navigateBack() {
                                NSSound.beep()
                            }
                        },
                        onFocusHistoryForward: {
                            if !tabManager.navigateForward() {
                                NSSound.beep()
                            }
                        }
                    )
                    .padding(
                        .leading,
                        CGFloat(titlebarDebugChromeSnapshot.leftControlsLeadingInset)
                    )
                    .padding(
                        .top,
                        minimalModeSidebarTitlebarControlsTopPadding
                    )
                }
            }
            .background(Color.clear)
            .modifier(ClearScrollBackground())
            .onReceive(
                extensionSidebarImmediateObservationPublisher(renderContext: renderContext)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                    extensionSidebarDebouncedObservationPublisher(renderContext: renderContext)
                        .receive(on: RunLoop.main)
                        .debounce(for: Self.extensionSidebarObservationCoalesceInterval, scheduler: RunLoop.main)
                ) { _ in
                refreshExtensionSidebarSnapshot()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: BrowserStackSidebar.stateDidLoadNotification)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshExtensionSidebarSnapshot()
            }
        }
    }

    func refreshExtensionSidebarSnapshot() {
        extensionSidebarUpdateToken &+= 1
    }

    private func extensionSidebarImmediateObservationPublisher(
        renderContext: WorkspaceListRenderContext
    ) -> AnyPublisher<Void, Never> {
        let publishers = renderContext.tabs.map(\.sidebarImmediateObservationPublisher)
        guard !publishers.isEmpty else {
            return Empty<Void, Never>().eraseToAnyPublisher()
        }
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    private func extensionSidebarDebouncedObservationPublisher(
        renderContext: WorkspaceListRenderContext
    ) -> AnyPublisher<Void, Never> {
        let publishers = renderContext.tabs.map(\.sidebarObservationPublisher)
        guard !publishers.isEmpty else {
            return Empty<Void, Never>().eraseToAnyPublisher()
        }
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    func extensionSidebarRenderModel(
        renderContext: WorkspaceListRenderContext,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        let _ = extensionSidebarUpdateToken
        let snapshot = extensionSidebarSnapshot(renderContext: renderContext)
        return extensionSidebarRenderModel(snapshot: snapshot, now: now)
    }

    func extensionSidebarRenderModel(
        snapshot: CmuxSidebarProviderSnapshot,
        now: Date
    ) -> CmuxSidebarProviderRenderModel {
        let descriptor = CmuxExtensionSidebarSelection.descriptor(for: effectiveExtensionSidebarProviderId)
        if let provider = CmuxExtensionSidebarSelection.provider(for: descriptor.id) {
            let context = CmuxSidebarProviderRenderContext(now: now)
            if let contextualProvider = provider as? any CmuxContextualSidebarProvider {
                return contextualProvider.render(snapshot: snapshot, context: context)
            }
            return provider.render(snapshot: snapshot)
        }
        return CmuxSidebarProviderRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    private func extensionSidebarSnapshot(
        renderContext: WorkspaceListRenderContext
    ) -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: renderContext.tabs)
    }

    func extensionSidebarSnapshotForCurrentTabs() -> CmuxSidebarProviderSnapshot {
        extensionSidebarSnapshot(workspaces: tabManager.tabs)
    }

    private func cmuxSidebarSnapshotForCurrentTabs() -> CmuxSidebarSnapshot {
        let snapshot = extensionSidebarSnapshotForCurrentTabs()
        return CmuxSidebarSnapshot(
            sequence: snapshot.sequence,
            windowID: snapshot.windowId,
            selectedWorkspaceID: snapshot.selectedWorkspaceId,
            workspaces: snapshot.workspaces.map { workspace in
                CmuxSidebarWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    detail: workspace.customDescription,
                    isPinned: workspace.isPinned,
                    rootPath: workspace.rootPath,
                    projectRootPath: workspace.projectRootPath,
                    gitBranch: workspace.branchSummary,
	                    unreadCount: workspace.unreadCount,
	                    latestNotification: workspace.latestNotificationText,
	                    listeningPorts: workspace.listeningPorts,
	                    pullRequestURLs: workspace.pullRequestURLs,
	                    surfaces: cmuxSidebarSurfaces(for: workspace)
	                )
	            }
	        )
	    }

    private func cmuxSidebarSurfaces(for workspace: CmuxSidebarProviderWorkspace) -> [CmuxSidebarSurface] {
        guard let liveWorkspace = tabManager.tabs.first(where: { $0.id == workspace.id }) else { return [] }
        return liveWorkspace.sidebarOrderedPanelIds().compactMap { panelId in
            guard let panel = liveWorkspace.panels[panelId] else { return nil }
            return CmuxSidebarSurface(
                id: panelId,
                title: liveWorkspace.panelTitle(panelId: panelId) ?? panel.displayTitle,
                kind: cmuxSidebarSurfaceKind(for: panel.panelType),
                isFocused: liveWorkspace.focusedPanelId == panelId,
                isPinned: liveWorkspace.isPanelPinned(panelId),
                unreadCount: liveWorkspace.manualUnreadPanelIds.contains(panelId) ? 1 : 0,
                workingDirectory: liveWorkspace.panelDirectories[panelId]
            )
        }
    }

    private func cmuxSidebarSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        case .extensionBrowser:
            return .unknown
        }
    }

    private func handleCMUXSidebarExtensionAction(
        _ action: CmuxSidebarAction
    ) -> CmuxSidebarActionResult {
        switch action {
        case .createWorkspace(let title, let workingDirectory, let select):
            let workspace = tabManager.addWorkspace(
                title: title,
                workingDirectory: workingDirectory,
                inheritWorkingDirectory: workingDirectory == nil,
                select: select
            )
            return CmuxSidebarActionResult(accepted: true, message: workspace.id.uuidString)

        case .selectWorkspace(let workspaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found")
                )
            }
            tabManager.selectWorkspace(workspace)
            return .accepted

        case .closeWorkspace(let workspaceId):
            guard tabManager.closeWorkspaceWithConfirmation(tabId: workspaceId) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.closeRejected", defaultValue: "Workspace could not be closed")
                )
            }
            return .accepted

        case .selectNextWorkspace:
            tabManager.selectNextTab()
            return .accepted

        case .selectPreviousWorkspace:
            tabManager.selectPreviousTab()
            return .accepted

        case .createTerminalSurface(let workspaceId):
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panel = workspace.newTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
            return panel.map { CmuxSidebarActionResult(accepted: true, message: $0.id.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .createBrowserSurface(let workspaceId, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let workspace = workspaceId.flatMap({ id in tabManager.tabs.first(where: { $0.id == id }) }) ?? tabManager.selectedWorkspace else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            if tabManager.selectedTabId != workspace.id {
                tabManager.selectWorkspace(workspace)
            }
            let panelId = tabManager.createBrowserSplit(direction: .right, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .selectSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.selectWorkspace(workspace)
            workspace.focusPanel(surfaceId)
            return .accepted

        case .selectNextSurface:
            tabManager.selectNextSurface()
            return .accepted

        case .selectPreviousSurface:
            tabManager.selectPreviousSurface()
            return .accepted

        case .closeSurface(let workspaceId, let surfaceId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return .rejected(String(localized: "sidebar.extensions.action.workspaceNotFound", defaultValue: "Workspace not found"))
            }
            guard workspace.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            tabManager.closePanelWithConfirmation(tabId: workspaceId, surfaceId: surfaceId)
            return .accepted

        case .splitTerminal(let workspaceId, let surfaceId, let direction):
            guard let splitDirection = splitDirection(from: direction),
                  let panelId = tabManager.createSplit(tabId: workspaceId, surfaceId: surfaceId, direction: splitDirection) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            return CmuxSidebarActionResult(accepted: true, message: panelId.uuidString)

        case .splitBrowser(let workspaceId, let surfaceId, let direction, let urlString):
            let validatedURL = cmuxSidebarExtensionOptionalHTTPURL(from: urlString)
            guard validatedURL.accepted else {
                return .rejected(String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened"))
            }
            guard let splitDirection = splitDirection(from: direction),
                  let tab = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  tab.panels[surfaceId] != nil else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))
            }
            tabManager.selectWorkspace(tab)
            tab.focusPanel(surfaceId)
            let panelId = tabManager.createBrowserSplit(direction: splitDirection, url: validatedURL.url)
            return panelId.map { CmuxSidebarActionResult(accepted: true, message: $0.uuidString) }
                ?? .rejected(String(localized: "sidebar.extensions.action.surfaceCreateRejected", defaultValue: "Surface could not be created"))

        case .toggleSurfaceZoom(let workspaceId, let surfaceId):
            guard tabManager.toggleSplitZoom(tabId: workspaceId, surfaceId: surfaceId) else {
                return .rejected(String(localized: "sidebar.extensions.action.surfaceNotFound", defaultValue: "Surface not found"))
            }
            return .accepted

        case .openURL(let urlString):
            guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString),
                  NSWorkspace.shared.open(url) else {
                return CmuxSidebarActionResult(
                    accepted: false,
                    message: String(localized: "sidebar.extensions.action.urlRejected", defaultValue: "URL could not be opened")
                )
            }
            return .accepted
        }
    }

    private func cmuxSidebarExtensionOptionalHTTPURL(from urlString: String?) -> (url: URL?, accepted: Bool) {
        guard let urlString, !urlString.isEmpty else {
            return (nil, true)
        }
        guard let url = cmuxSidebarExtensionRequiredHTTPURL(from: urlString) else {
            return (nil, false)
        }
        return (url, true)
    }

    private func cmuxSidebarExtensionRequiredHTTPURL(from urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    private func splitDirection(from direction: CmuxSidebarSplitDirection) -> SplitDirection? {
        switch direction {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    private func extensionSidebarSnapshot(workspaces: [Workspace]) -> CmuxSidebarProviderSnapshot {
        CmuxSidebarProviderSnapshot(
            sequence: UInt64(max(0, CmuxEventBus.shared.latestSequence)),
            selectedWorkspaceId: tabManager.selectedTabId,
            workspaces: workspaces.map(extensionWorkspaceSnapshot(for:)),
            windowId: windowId
        )
    }

    func extensionWorkspaceSnapshot(for workspace: Workspace) -> CmuxSidebarProviderWorkspace {
        let rootPath = extensionSidebarRootPath(for: workspace)
        return CmuxSidebarProviderWorkspace(
            id: workspace.id,
            title: workspace.title,
            customDescription: workspace.customDescription,
            isPinned: workspace.isPinned,
            rootPath: rootPath,
            projectRootPath: workspace.extensionSidebarProjectRootPath,
            branchSummary: workspace.gitBranch?.branch,
            remoteDisplayTarget: workspace.remoteDisplayTarget,
            remoteConnectionState: workspace.remoteConnectionState.rawValue,
            unreadCount: notificationStore.unreadCount(forTabId: workspace.id),
            latestNotificationText: notificationStore.latestNotification(forTabId: workspace.id).flatMap {
                let text = $0.body.isEmpty ? $0.title : $0.body
                return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            },
            latestSubmittedMessage: workspace.latestSubmittedMessage,
            latestSubmittedAt: workspace.latestSubmittedAt,
            listeningPorts: workspace.listeningPorts,
            pullRequestURLs: workspace.sidebarPullRequestsInDisplayOrder().map { $0.url.absoluteString },
            panelDirectories: workspace.sidebarDirectoriesInDisplayOrder(),
            gitBranches: workspace.sidebarGitBranchesInDisplayOrder().map {
                CmuxSidebarProviderGitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }
        )
    }

    private func extensionSidebarRootPath(for workspace: Workspace) -> String? {
        workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

}
