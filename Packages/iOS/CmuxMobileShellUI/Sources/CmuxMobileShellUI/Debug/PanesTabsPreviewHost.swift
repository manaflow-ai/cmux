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

    @State private var selectedSurfaceID = Self.claudeSurfaceID
    @State private var isPaneMapPresented = false
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
        ],
        layout: MobilePaneLayout(
            version: 12,
            focusedPaneID: "preview-pane-left",
            root: .split(
                MobilePaneSplit(
                    id: "preview-split-root",
                    orientation: .horizontal,
                    ratio: 0.55,
                    first: .pane(
                        MobilePaneNode(
                            id: "preview-pane-left",
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
                    second: .split(
                        MobilePaneSplit(
                            id: "preview-split-right",
                            orientation: .vertical,
                            ratio: 0.5,
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
        ZStack(alignment: .topTrailing) {
            terminalTheme.terminalBackgroundColor
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            WorkspaceUtilitiesMenu(
                showsViewAsText: false,
                showsPaneMap: true,
                terminalTheme: terminalTheme,
                presentPaneMap: presentPaneMap,
                openTextSheet: {},
                copyDebugLogs: {},
                sendFeedback: {}
            )
            .frame(width: 44, height: 44)
            .padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SurfaceDeckBar(value: deckValue, actions: deckActions, terminalTheme: terminalTheme)
                .equatable()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .fullScreenCover(isPresented: $isPaneMapPresented) {
            if let layout = workspace.layout {
                PaneMapOverlay(
                    value: PaneMapValue(
                        workspaceName: workspace.name,
                        layout: layout,
                        phoneSelectedSurfaceID: selectedSurfaceID,
                        agentStateKindsBySurfaceID: agentStateKindsBySurfaceID
                    ),
                    terminalTheme: terminalTheme,
                    fetchPreviews: Self.fetchFixturePreviews,
                    selectTerminal: { selectedSurfaceID = $0.rawValue },
                    dismiss: { isPaneMapPresented = false }
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
        isPaneMapPresented = true
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
        ]

        var previews: [String: MobileTerminalRenderGridFrame] = [:]
        for surfaceID in selectedSurfaceIDs + remainingSurfaceIDs where previews[surfaceID] == nil {
            guard let text = textBySurfaceID[surfaceID],
                  let frame = try? MobileTerminalRenderGridFrame.fromPlainRows(
                    surfaceID: surfaceID,
                    stateSeq: 1,
                    columns: 50,
                    rows: 7,
                    text: text
                  ) else {
                continue
            }
            previews[surfaceID] = frame
        }
        return previews
    }
}
#endif
