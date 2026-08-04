#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import os
import SwiftUI
import UIKit

/// Fixture-driven host for exercising the production panes-and-tabs UI without a paired Mac.
struct PanesTabsPreviewHost: View {
    private static let logger = Logger(subsystem: "dev.cmux.ios", category: "PanesTabsPreviewHost")
    private static let claudeSurfaceID = "preview-claude"
    private static let zshSurfaceID = "preview-zsh"
    private static let testsSurfaceID = "preview-bun-tests"
    private static let logSurfaceID = "preview-server-log"
    private static let browserSurfaceID = "preview-browser"
    private static let gitSurfaceID = "preview-git"

    @State private var selectedSurfaceID = Self.claudeSurfaceID
    @Namespace private var paneZoomNamespace
    @State private var paneZoomPresentation = PaneZoomPresentationState()
    @State private var orderedFixturePaneIDs = [
        "preview-pane-left-top",
        "preview-pane-left-bottom",
        "preview-pane-tests",
        "preview-pane-server",
    ]
    @State private var paneMapRefreshTrigger = 0
    @State private var fixtureLayoutRevision = 0
    @State private var isPaneMapRefreshing = false
    @State private var contentWidth: CGFloat = 0
    @State private var autoplayStep = 0
    private let terminalTheme = TerminalTheme.monokai

    private let workspace = MobileWorkspacePreview(
        id: "preview-api-server",
        name: "api-server",
        terminals: [
            MobileTerminalPreview(
                id: MobileTerminalPreview.ID(rawValue: Self.claudeSurfaceID),
                name: "claude",
                isFocused: true
            ),
            MobileTerminalPreview(
                id: MobileTerminalPreview.ID(rawValue: Self.zshSurfaceID),
                name: "zsh"
            ),
            MobileTerminalPreview(
                id: MobileTerminalPreview.ID(rawValue: Self.testsSurfaceID),
                name: "bun test --watch"
            ),
            MobileTerminalPreview(
                id: MobileTerminalPreview.ID(rawValue: Self.logSurfaceID),
                name: "server.log"
            ),
            MobileTerminalPreview(
                id: MobileTerminalPreview.ID(rawValue: Self.gitSurfaceID),
                name: "lazygit"
            ),
        ],
        layout: MobilePaneLayout(
            version: 12,
            focusedPaneID: "preview-pane-left-top",
            root: .split(
                MobilePaneSplit(
                    id: "preview-split-root",
                    orientation: .horizontal,
                    ratio: 0.6,
                    first: .split(
                        MobilePaneSplit(
                            id: "preview-split-left",
                            orientation: .vertical,
                            ratio: 0.35,
                            first: .pane(
                                MobilePaneNode(
                                    id: "preview-pane-left-top",
                                    selectedSurfaceID: Self.claudeSurfaceID,
                                    surfaces: [
                                        MobilePaneSurface(
                                            id: Self.claudeSurfaceID,
                                            type: .terminal,
                                            title: "claude"
                                        ),
                                        MobilePaneSurface(
                                            id: Self.zshSurfaceID,
                                            type: .terminal,
                                            title: "zsh"
                                        ),
                                    ]
                                )
                            ),
                            second: .pane(
                                MobilePaneNode(
                                    id: "preview-pane-left-bottom",
                                    selectedSurfaceID: Self.gitSurfaceID,
                                    surfaces: [
                                        MobilePaneSurface(
                                            id: Self.gitSurfaceID,
                                            type: .terminal,
                                            title: "lazygit"
                                        )
                                    ]
                                )
                            )
                        )
                    ),
                    second: .split(
                        MobilePaneSplit(
                            id: "preview-split-right",
                            orientation: .vertical,
                            ratio: 0.65,
                            first: .pane(
                                MobilePaneNode(
                                    id: "preview-pane-tests",
                                    selectedSurfaceID: Self.testsSurfaceID,
                                    surfaces: [
                                        MobilePaneSurface(
                                            id: Self.testsSurfaceID,
                                            type: .terminal,
                                            title: "bun test --watch"
                                        ),
                                    ]
                                )
                            ),
                            second: .pane(
                                MobilePaneNode(
                                    id: "preview-pane-server",
                                    selectedSurfaceID: Self.logSurfaceID,
                                    surfaces: [
                                        MobilePaneSurface(
                                            id: Self.logSurfaceID,
                                            type: .terminal,
                                            title: "server.log"
                                        ),
                                        MobilePaneSurface(
                                            id: Self.browserSurfaceID,
                                            type: .browser,
                                            title: "localhost:3000"
                                        ),
                                    ]
                                )
                            )
                        )
                    )
                )
            )
        )
    )

    private let agentStateKindsBySurfaceID: [String: ChatAgentStateKind] = [
        Self.claudeSurfaceID: .working,
        Self.testsSurfaceID: .needsInput,
    ]

    var body: some View {
        Group {
            if let layout = fixtureLayout {
                PaneZoomNavigationStack(
                    presentation: $paneZoomPresentation,
                    terminalTheme: terminalTheme
                ) {
                    PaneMapOverlay(
                        value: PaneMapValue(
                            layout: layout,
                            phoneSelectedSurfaceID: selectedSurfaceID,
                            agentStateKindsBySurfaceID: agentStateKindsBySurfaceID
                        ),
                        terminalTheme: terminalTheme,
                        zoomNamespace: paneZoomNamespace,
                        isVisible: !paneZoomPresentation.isTerminalPresented,
                        allowsReordering: true,
                        refreshTrigger: paneMapRefreshTrigger,
                        fetchPreviews: Self.fetchFixturePreviews,
                        selectTerminal: presentTerminalFromPaneMap,
                        reorderPanes: reorderFixturePanes,
                        refreshingChanged: { isPaneMapRefreshing = $0 }
                    )
                    .accessibilityHidden(paneZoomPresentation.isTerminalPresented)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                    .navigationTitle(workspace.name)
                    .mobileTerminalNavigationChrome(theme: terminalTheme)
                    .toolbar { previewToolbar(mode: .paneMap) }
                    .navigationBarBackButtonHidden(true)
                    .background { autoplayDriver(for: .paneMap) }
                } terminal: {
                    terminalPreviewEndpoint
                        .mobileSurfaceDeckInset(
                            isVisible: paneZoomPresentation.isTerminalPresented,
                            value: deckValue,
                            actions: deckActions,
                            terminalTheme: terminalTheme
                        )
                        .navigationBarBackButtonHidden(true)
                        .navigationTransition(
                            .zoom(
                                sourceID: paneZoomSourceSurfaceID,
                                in: paneZoomNamespace
                            )
                        )
                }
            } else {
                terminalPreviewEndpoint
                    .mobileSurfaceDeckInset(
                        isVisible: paneZoomPresentation.isTerminalPresented,
                        value: deckValue,
                        actions: deckActions,
                        terminalTheme: terminalTheme
                    )
            }
        }
        .background {
            terminalTheme.terminalBackgroundColor
                .ignoresSafeArea()
        }
    }

    private var terminalPreviewEndpoint: some View {
        ZStack(alignment: .topTrailing) {
            terminalTheme.terminalBackgroundColor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            terminalTheme.terminalBackgroundColor
                .ignoresSafeArea(.container, edges: [.horizontal, .top, .bottom])
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .navigationTitle(workspace.name)
        .mobileTerminalNavigationChrome(theme: terminalTheme)
        .toolbar { previewToolbar(mode: .terminal) }
        .background { autoplayDriver(for: .terminal) }
        .accessibilityIdentifier("PanesTabsPreviewHost")
    }

    private var deckValue: SurfaceDeckValue {
        SurfaceDeckValue(
            workspace: workspace,
            selectedSurfaceID: selectedSurfaceID,
            agentStateKindsBySurfaceID: agentStateKindsBySurfaceID,
            canCreateWorkspace: true
        )
    }

    private var deckActions: SurfaceDeckActions {
        SurfaceDeckActions(
            selectTerminal: { selectedSurfaceID = $0.rawValue },
            presentPaneMap: presentPaneMap,
            createTerminal: {},
            openBrowser: {},
            createWorkspace: {}
        )
    }

    private func presentPaneMap() {
        paneZoomPresentation.presentPaneMap(from: selectedSurfaceID)
    }

    private func presentTerminalFromPaneMap(_ terminalID: MobileTerminalPreview.ID) {
        paneZoomPresentation.presentTerminal(surfaceID: terminalID.rawValue)
        selectedSurfaceID = terminalID.rawValue
    }

    private func returnToTerminalFromPaneMap() {
        paneZoomPresentation.presentTerminal(surfaceID: paneZoomSourceSurfaceID)
    }

    private enum AutoplayLocation {
        case terminal
        case paneMap
    }

    private func autoplayDriver(for location: AutoplayLocation) -> some View {
        PanesTabsAutoplayDriver(
            isEnabled: ProcessInfo.processInfo.environment["CMUX_UITEST_PANES_PREVIEW_AUTOPLAY"] == "1"
                && fixtureLayout != nil,
            location: location,
            isTerminalPresented: paneZoomPresentation.isTerminalPresented,
            step: $autoplayStep,
            presentPaneMap: presentPaneMap,
            presentTerminal: {
                presentTerminalFromPaneMap(MobileTerminalPreview.ID(rawValue: Self.claudeSurfaceID))
            },
            returnToTerminal: returnToTerminalFromPaneMap
        )
        .frame(width: 1, height: 1)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @MainActor
    private struct PanesTabsAutoplayDriver: UIViewRepresentable {
        let isEnabled: Bool
        let location: AutoplayLocation
        let isTerminalPresented: Bool
        @Binding var step: Int
        let presentPaneMap: () -> Void
        let presentTerminal: () -> Void
        let returnToTerminal: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            context.coordinator.update(self)
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.update(self)
        }

        static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
            coordinator.cancel()
        }

        @MainActor
        final class Coordinator {
            private var task: Task<Void, Never>?
            private var scheduledKey: String?

            func update(_ parent: PanesTabsAutoplayDriver) {
                guard parent.isEnabled else {
                    cancel()
                    return
                }
                guard let plan = Plan(
                    step: parent.step,
                    location: parent.location,
                    isTerminalPresented: parent.isTerminalPresented
                ) else {
                    cancel()
                    return
                }
                let nextKey = [
                    "\(parent.step)",
                    String(describing: parent.location),
                    parent.isTerminalPresented ? "terminal" : "paneMap",
                ].joined(separator: ":")
                guard scheduledKey != nextKey else { return }
                cancel()
                scheduledKey = nextKey
                PanesTabsPreviewHost.logger.notice("autoplay: schedule \(nextKey, privacy: .public)")
                task = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(plan.delay))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          parent.step == plan.expectedStep else { return }
                    PanesTabsPreviewHost.logger.notice("autoplay: fire \(nextKey, privacy: .public)")
                    parent.step = plan.nextStep
                    parent.run(plan.action)
                    self?.cancel()
                }
            }

            func cancel() {
                task?.cancel()
                task = nil
                scheduledKey = nil
            }
        }

        private enum Action: Sendable {
            case presentPaneMap
            case presentTerminal
            case returnToTerminal
        }

        private func run(_ action: Action) {
            switch action {
            case .presentPaneMap:
                presentPaneMap()
            case .presentTerminal:
                presentTerminal()
            case .returnToTerminal:
                returnToTerminal()
            }
        }

        private struct Plan: Sendable {
            let expectedStep: Int
            let nextStep: Int
            let delay: TimeInterval
            let action: Action

            init?(step: Int, location: AutoplayLocation, isTerminalPresented: Bool) {
                switch (step, location, isTerminalPresented) {
                case (0, .terminal, true):
                    expectedStep = 0
                    nextStep = 1
                    delay = 5
                    action = .presentPaneMap
                case (1, .paneMap, false):
                    expectedStep = 1
                    nextStep = 2
                    delay = 1.1
                    action = .presentTerminal
                case (2, .terminal, true):
                    expectedStep = 2
                    nextStep = 3
                    delay = 1.1
                    action = .presentPaneMap
                case (3, .paneMap, false):
                    expectedStep = 3
                    nextStep = 4
                    delay = 1.1
                    action = .returnToTerminal
                default:
                    return nil
                }
            }
        }
    }

    private var paneZoomSourceSurfaceID: String {
        paneZoomPresentation.sourceSurfaceID ?? selectedSurfaceID
    }

    private enum PreviewToolbarMode {
        case paneMap
        case terminal
    }

    @ToolbarContentBuilder
    private func previewToolbar(mode: PreviewToolbarMode) -> some ToolbarContent {
        ToolbarItem(id: "workspace-back", placement: .topBarLeading) {
            WorkspaceBackButton(unreadCount: 2, action: {})
        }
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .topBarLeading)
        }
        ToolbarItem(id: "workspace-title", placement: .topBarLeading) {
            previewWorkspaceTitleMenu(mode: mode)
        }
        switch mode {
        case .paneMap:
            ToolbarItem(id: "pane-map-refresh", placement: .topBarTrailing) {
                PaneMapRefreshToolbarButton(
                    isRefreshing: isPaneMapRefreshing,
                    refresh: { paneMapRefreshTrigger &+= 1 }
                )
            }
            ToolbarItem(id: "workspace-trailing", placement: .topBarTrailing) {
                PaneMapDoneToolbarButton(done: returnToTerminalFromPaneMap)
            }
        case .terminal:
            ToolbarItem(id: "workspace-trailing", placement: .topBarTrailing) {
                previewToolbarTrailingContent
            }
        }
    }

    private func previewWorkspaceTitleMenu(mode: PreviewToolbarMode) -> some View {
        let value = WorkspaceTitleMenuValue(
            contentWidth: contentWidth,
            hasBackButton: true,
            hasTrailingCluster: true,
            hasChatToggle: false,
            reservesPaneMapControls: true,
            isEnabled: true,
            workspaceName: workspace.name,
            hasUnread: false,
            canCustomizeWorkspace: false,
            canRenameWorkspace: true,
            canToggleReadState: false,
            canCloseWorkspace: false,
            labelToken: .standard(
                title: workspace.name,
                subtitle: previewToolbarSubtitle(mode: mode)
            ),
            terminalTheme: terminalTheme
        )
        return WorkspaceTitleMenu(
            value: value,
            menuContent: {
                WorkspaceTitleMenuContent(
                    workspaceName: value.workspaceName,
                    hasUnread: value.hasUnread,
                    canCustomizeWorkspace: value.canCustomizeWorkspace,
                    canRenameWorkspace: value.canRenameWorkspace,
                    canToggleReadState: value.canToggleReadState,
                    canCloseWorkspace: value.canCloseWorkspace,
                    presentCustomization: {},
                    presentRename: {},
                    toggleReadState: {},
                    requestClose: {}
                )
            },
            label: {
                WorkspaceToolbarTitleView(
                    title: workspace.name,
                    subtitle: previewToolbarSubtitle(mode: mode)
                )
            }
        )
        .equatable()
    }

    private func previewToolbarSubtitle(mode: PreviewToolbarMode) -> String? {
        switch mode {
        case .paneMap:
            guard let layout = fixtureLayout else { return nil }
            return PaneMapValue(
                layout: layout,
                phoneSelectedSurfaceID: selectedSurfaceID,
                agentStateKindsBySurfaceID: agentStateKindsBySurfaceID
            ).countSubtitle
        case .terminal:
            return workspace.terminals.first {
                $0.id.rawValue == selectedSurfaceID
            }?.name
        }
    }

    private var previewToolbarTrailingContent: some View {
        WorkspaceUtilitiesMenu(
            showsViewAsText: false,
            showsPaneMap: true,
            terminalTheme: terminalTheme,
            presentPaneMap: presentPaneMap,
            openTextSheet: {},
            copyDebugLogs: {},
            sendFeedback: {}
        )
    }

    private var fixtureLayout: MobilePaneLayout? {
        guard let baseLayout = workspace.layout else { return nil }
        let panesByID = Dictionary(
            uniqueKeysWithValues: baseLayout.orderedPanes.map { ($0.id, $0) }
        )
        let slotPaneIDs = baseLayout.orderedPanes.map(\.id)
        let contentsBySlotID = Dictionary(
            uniqueKeysWithValues: zip(slotPaneIDs, orderedFixturePaneIDs).compactMap {
                slotID, contentID in
                panesByID[contentID].map { (slotID, $0) }
            }
        )
        let focusedPaneID = baseLayout.focusedPaneID.flatMap { focusedContentID in
            orderedFixturePaneIDs.firstIndex(of: focusedContentID).map {
                slotPaneIDs[$0]
            }
        }
        return MobilePaneLayout(
            version: baseLayout.version + paneMapRefreshTrigger + fixtureLayoutRevision,
            focusedPaneID: focusedPaneID,
            root: replacingFixturePaneContents(
                in: baseLayout.root,
                contentsBySlotID: contentsBySlotID
            )
        )
    }

    private func replacingFixturePaneContents(
        in node: MobilePaneLayout.Node,
        contentsBySlotID: [String: MobilePaneNode]
    ) -> MobilePaneLayout.Node {
        switch node {
        case .pane(let slot):
            guard let content = contentsBySlotID[slot.id] else { return node }
            return .pane(MobilePaneNode(
                id: slot.id,
                selectedSurfaceID: content.selectedSurfaceID,
                surfaces: content.surfaces
            ))
        case .split(let split):
            return .split(MobilePaneSplit(
                id: split.id,
                orientation: split.orientation,
                ratio: split.ratio,
                first: replacingFixturePaneContents(
                    in: split.first,
                    contentsBySlotID: contentsBySlotID
                ),
                second: replacingFixturePaneContents(
                    in: split.second,
                    contentsBySlotID: contentsBySlotID
                )
            ))
        }
    }

    @MainActor
    private func reorderFixturePanes(
        _ orderedPaneIDs: [String],
        baseLayoutRevision: Int
    ) async -> Bool {
        guard let slotPaneIDs = workspace.layout?.orderedPanes.map(\.id),
              orderedPaneIDs.count == slotPaneIDs.count,
              Set(orderedPaneIDs) == Set(slotPaneIDs) else {
            return false
        }
        let currentContentBySlotID = Dictionary(
            uniqueKeysWithValues: zip(slotPaneIDs, orderedFixturePaneIDs)
        )
        orderedFixturePaneIDs = orderedPaneIDs.compactMap {
            currentContentBySlotID[$0]
        }
        fixtureLayoutRevision &+= 1
        await Task.yield()
        return true
    }

    private static func fetchFixturePreviews(
        selectedSurfaceIDs: [String],
        remainingSurfaceIDs: [String]
    ) async -> [String: MobileTerminalRenderGridFrame] {
        let textBySurfaceID = [
            claudeSurfaceID: """
            ╭─ Claude Code ─────────────────────────╮
            │ I’ll inspect the routing layer first. │
            ╰───────────────────────────────────────╯
            Read  Sources/API/Router.ts
            Edit  Sources/API/Router.ts
            Running focused tests…
            """,
            zshSurfaceID: """
            api-server % git status --short
             M Sources/API/Router.ts
            api-server % bun run lint
            Checked 42 files in 318ms. No fixes needed.
            api-server %
            """,
            testsSurfaceID: """
            bun test v1.2.18
            ✓ auth middleware (12 tests)
            ✓ router params (8 tests)
            ✗ websocket reconnect
              expected 2 messages, received 1
            Waiting for file changes…
            """,
            logSurfaceID: """
            14:32:08 INFO  listening on http://localhost:3000
            14:32:11 GET   /api/health 200 3ms
            14:32:14 POST  /api/chat 202 18ms
            14:32:15 INFO  stream connected client=mobile
            14:32:19 GET   /assets/app.js 304 2ms
            """,
            gitSurfaceID: """
            ┌─ Status ───────────────┐┌─ Staged ───────────────┐
            │M Sources/API/Router.ts ││                        │
            │M Tests/RouterTests.ts  ││                        │
            └────────────────────────┘└────────────────────────┘
            ┌─ Commits ────────────────────────────────────────┐
            │d85a567 Test mobile observer via emitted updates  │
            └──────────────────────────────────────────────────┘
            """,
        ]

        var previews: [String: MobileTerminalRenderGridFrame] = [:]
        for surfaceID in selectedSurfaceIDs + remainingSurfaceIDs where previews[surfaceID] == nil {
            guard let text = textBySurfaceID[surfaceID] else {
                continue
            }
            if surfaceID == claudeSurfaceID {
                previews[surfaceID] = try? styledClaudeFrame()
            } else {
                previews[surfaceID] = try? MobileTerminalRenderGridFrame.fromPlainRows(
                    surfaceID: surfaceID,
                    stateSeq: 1,
                    columns: 50,
                    rows: 12,
                    text: text
                )
            }
        }
        return previews
    }

    private static func styledClaudeFrame() throws -> MobileTerminalRenderGridFrame {
        var effectiveTheme = TerminalTheme.monokai
        effectiveTheme.background = "#123456"
        return try MobileTerminalRenderGridFrame(
            surfaceID: claudeSurfaceID,
            stateSeq: 1,
            columns: 50,
            rows: 12,
            styles: [
                .default,
                .init(id: 1, foreground: "#a6e22e", bold: true),
                .init(id: 2, foreground: "#272822", background: "#66d9ef", bold: true),
                .init(id: 3, foreground: "#e6db74"),
            ],
            rowSpans: [
                .init(row: 0, column: 0, styleID: 2, text: " Claude Code "),
                .init(row: 1, column: 0, styleID: 1, text: "╭──────────────────────────────────────────────╮"),
                .init(row: 2, column: 0, styleID: 1, text: "│"),
                .init(row: 2, column: 2, text: "I’ll inspect the routing layer first."),
                .init(row: 2, column: 47, styleID: 1, text: "│"),
                .init(row: 3, column: 0, styleID: 1, text: "╰──────────────────────────────────────────────╯"),
                .init(row: 5, column: 0, styleID: 3, text: "Read"),
                .init(row: 5, column: 6, text: "Sources/API/Router.ts"),
                .init(row: 6, column: 0, styleID: 3, text: "Edit"),
                .init(row: 6, column: 6, text: "Sources/API/Router.ts"),
                .init(row: 8, column: 0, styleID: 1, text: "Running focused tests…"),
            ],
            terminalBackground: "#abcdef",
            terminalTheme: effectiveTheme
        )
    }
}
#endif
