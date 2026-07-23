#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileShellModel
import SwiftUI

/// Fixture-driven host for exercising the production panes-and-tabs UI without a paired Mac.
struct PanesTabsPreviewHost: View {
    private static let claudeSurfaceID = "preview-claude"
    private static let zshSurfaceID = "preview-zsh"
    private static let testsSurfaceID = "preview-bun-tests"
    private static let logSurfaceID = "preview-server-log"
    private static let browserSurfaceID = "preview-browser"
    private static let gitSurfaceID = "preview-git"

    @State private var selectedSurfaceID = Self.claudeSurfaceID
    @Namespace private var paneZoomNamespace
    @State private var paneZoomPresentation = PaneZoomPresentationState()
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
        if let layout = workspace.layout {
            PaneMapOverlay(
                value: PaneMapValue(
                    workspaceName: workspace.name,
                    layout: layout,
                    phoneSelectedSurfaceID: selectedSurfaceID,
                    agentStateKindsBySurfaceID: agentStateKindsBySurfaceID
                ),
                terminalTheme: terminalTheme,
                zoomNamespace: paneZoomNamespace,
                isVisible: !paneZoomPresentation.isTerminalPresented,
                fetchPreviews: Self.fetchFixturePreviews,
                selectTerminal: presentTerminalFromPaneMap,
                dismiss: returnToTerminalFromPaneMap
            )
            .accessibilityHidden(paneZoomPresentation.isTerminalPresented)
            .fullScreenCover(
                isPresented: terminalPresentationBinding,
                onDismiss: reconcilePaneMapAfterInteractiveDismissal
            ) {
                NavigationStack {
                    terminalPreviewEndpoint
                }
                .navigationTransition(
                    .zoom(
                        sourceID: paneZoomSourceSurfaceID,
                        in: paneZoomNamespace
                    )
                )
            }
        } else {
            terminalPreviewEndpoint
        }
    }

    private var terminalPreviewEndpoint: some View {
        ZStack(alignment: .topTrailing) {
            terminalTheme.terminalBackgroundColor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SurfaceDeckBar(value: deckValue, actions: deckActions, terminalTheme: terminalTheme)
                .equatable()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle(workspace.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
        }
        .accessibilityElement(children: .contain)
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

    private var terminalPresentationBinding: Binding<Bool> {
        Binding(
            get: { paneZoomPresentation.isTerminalPresented },
            set: { isPresented in
                paneZoomPresentation.presentationDidChange(
                    isTerminalPresented: isPresented
                )
            }
        )
    }

    private func reconcilePaneMapAfterInteractiveDismissal() {
        paneZoomPresentation.presentationDidChange(isTerminalPresented: false)
    }

    private var paneZoomSourceSurfaceID: String {
        paneZoomPresentation.sourceSurfaceID ?? selectedSurfaceID
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
