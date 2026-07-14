#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Offline synthetic fixture for M6 simulator screenshots and interaction checks.
struct PaneTabRedesignPreviewView: View {
    let mode: String
    @State private var path: [String]
    @Namespace private var paneTransitionNamespace

    init(mode: String) {
        self.mode = mode
        _path = State(initialValue: mode == "hub" ? [] : [Self.primaryPaneID])
    }

    var body: some View {
        NavigationStack(path: $path) {
            WorkspaceHubView(
                workspace: Self.workspace,
                layout: Self.layout,
                connectionStatus: .connected,
                previewUpdates: previewUpdates,
                browserPreviewUpdates: browserPreviewUpdates,
                chatCards: Self.chatCards,
                transitionNamespace: paneTransitionNamespace,
                selectPane: { pane in path.append(pane.id) },
                backButtonConfiguration: nil
            )
            .navigationDestination(for: String.self) { paneID in
                PaneTabRedesignDetailFixture(
                    paneID: paneID,
                    startsWithHandle: mode == "handle",
                    previewUpdates: previewUpdates,
                    browserPreviewUpdates: browserPreviewUpdates
                )
                .navigationTransition(.zoom(sourceID: paneID, in: paneTransitionNamespace))
                .background(InteractiveSwipeBackEnabler())
            }
        }
        .environment(MobileDisplaySettings(defaults: UserDefaults(suiteName: "PaneTabRedesignPreview")!))
    }

    private func previewUpdates(surfaceID: String) -> AsyncStream<PreviewGridSnapshot> {
        AsyncStream { continuation in
            continuation.yield(Self.snapshot(surfaceID: surfaceID))
            continuation.finish()
        }
    }

    private func browserPreviewUpdates(
        surfaceID: String,
        resolution: MobileBrowserPreviewResolution
    ) -> AsyncStream<MobileBrowserPreviewFrame> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    fileprivate static let primaryPaneID = "pane-editor"

    fileprivate static let workspace = MobileWorkspacePreview(
        id: "workspace-polish",
        macDeviceID: "preview-mac",
        macDisplayName: "Studio Mac",
        name: "iOS pane polish",
        terminals: tabs.compactMap { tab in
            guard tab.kind == .terminal else { return nil }
            return MobileTerminalPreview(id: .init(rawValue: tab.id), name: tab.name)
        },
        supportsWorkspaceLayout: true,
        supportsBrowserPreview: true
    )

    private static let tabs: [MobileWorkspaceTab] = [
        .init(id: "terminal-editor", name: "Editor and implementation notes", kind: .terminal, isActive: true, isReady: true, agentStatus: .running, hasUnread: false),
        .init(id: "terminal-tests", name: "Tests", kind: .terminal, isActive: false, isReady: true, agentStatus: .needsInput, hasUnread: true),
        .init(id: "browser-docs", name: "SwiftUI documentation", kind: .browser, isActive: false, isReady: true, agentStatus: nil, hasUnread: false),
    ]

    private static let layout = MobileWorkspaceLayout(
        workspaceID: workspace.id.rawValue,
        root: .split(.init(
            id: "split-root",
            orientation: .horizontal,
            ratio: 0.58,
            first: .split(.init(
                id: "split-leading",
                orientation: .vertical,
                ratio: 0.56,
                first: .pane(.init(id: primaryPaneID, frame: .unit, tabs: tabs)),
                second: .split(.init(
                    id: "split-leading-bottom",
                    orientation: .horizontal,
                    ratio: 0.5,
                    first: .pane(.init(id: "pane-tests", frame: .unit, tabs: [tabs[1]])),
                    second: .pane(.init(id: "pane-browser", frame: .unit, tabs: [tabs[2]]))
                ))
            )),
            second: .split(.init(
                id: "split-trailing",
                orientation: .vertical,
                ratio: 0.34,
                first: .pane(.init(id: "pane-server", frame: .unit, tabs: [.init(id: "terminal-server", name: "Development server with a long Japanese-safe label", kind: .terminal, isActive: true, isReady: true, agentStatus: .running, hasUnread: false)])),
                second: .split(.init(
                    id: "split-trailing-bottom",
                    orientation: .vertical,
                    ratio: 0.5,
                    first: .pane(.init(id: "pane-review", frame: .unit, tabs: [.init(id: "terminal-review", name: "Review", kind: .terminal, isActive: true, isReady: true, agentStatus: .needsInput, hasUnread: true)])),
                    second: .pane(.init(id: "pane-notes", frame: .unit, tabs: [.init(id: "terminal-notes", name: "Notes", kind: .terminal, isActive: true, isReady: true, agentStatus: .idle, hasUnread: false)]))
                ))
            ))
        )),
        activePaneID: primaryPaneID
    )

    private static let chatCards = [
        PaneChatCardSnapshot(
            id: "chat-editor",
            terminalID: "terminal-editor",
            title: "Agent chat",
            agentStatus: .needsInput
        ),
    ]

    fileprivate static func snapshot(surfaceID: String) -> PreviewGridSnapshot {
        let lines = [
            "$ swift test --package-path Packages/iOS/CmuxMobileShellModel",
            "Building for debugging...",
            "Test run started",
            "✓ topology projection",
            "✓ attention ordering",
            "Ready for polish",
        ]
        return PreviewGridSnapshot(
            surfaceID: surfaceID,
            stateSeq: 1,
            columns: 72,
            rows: 18,
            activeScreen: .primary,
            lines: lines.enumerated().map { row, text in
                PreviewGridLine(
                    row: row,
                    spans: [PreviewGridSpan(
                        column: 0,
                        cellWidth: text.count,
                        text: text,
                        style: PreviewGridStyle()
                    )]
                )
            },
            hasBaseline: true
        )
    }
}

private struct PaneTabRedesignDetailFixture: View {
    let paneID: String
    let startsWithHandle: Bool
    let previewUpdates: (String) -> AsyncStream<PreviewGridSnapshot>
    let browserPreviewUpdates: (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    @State private var selectedCardID = "terminal-editor"
    @State private var stripVisible: Bool
    @State private var attentionShelfEnabled = false

    init(
        paneID: String,
        startsWithHandle: Bool,
        previewUpdates: @escaping (String) -> AsyncStream<PreviewGridSnapshot>,
        browserPreviewUpdates: @escaping (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    ) {
        self.paneID = paneID
        self.startsWithHandle = startsWithHandle
        self.previewUpdates = previewUpdates
        self.browserPreviewUpdates = browserPreviewUpdates
        _stripVisible = State(initialValue: !startsWithHandle)
    }

    var body: some View {
        GeometryReader { geometry in
            TerminalGridThumbnailView(snapshot: PaneTabRedesignPreviewView.snapshot(surfaceID: selectedCardID))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(TerminalPalette.background)
        }
            // Production terminal content owns its keyboard geometry and opts
            // out of SwiftUI keyboard avoidance. Mirror that contract here so
            // stale simulator keyboard state cannot lift the strip off the
            // physical bottom edge in visual fixtures.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if stripVisible {
                    PaneTabStripView(
                        cards: displayedCards,
                        selectedCardID: selectedCardID,
                        attentionShelfEnabled: attentionShelfEnabled,
                        connectionStatus: .connected,
                        supportsBrowserPreview: true,
                        previewUpdates: previewUpdates,
                        browserPreviewUpdates: browserPreviewUpdates,
                        select: { selectedCardID = $0.id },
                        toggleAttentionShelf: { attentionShelfEnabled.toggle() },
                        createTerminal: {}
                    )
                } else {
                    PaneTabStripHandle(
                        revealByTap: { stripVisible = true },
                        revealByUpwardDrag: { stripVisible = true }
                    )
                }
            }
            .navigationTitle(PaneTabRedesignPreviewView.workspace.name)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("PaneTabRedesignDetailFixture-\(paneID)")
    }

    private var displayedCards: [PaneTabStripCardSnapshot] {
        let cards = [
            PaneTabStripCardSnapshot(id: "terminal-editor", title: "Editor and implementation notes", kind: .terminal, isReady: true, agentStatus: .running, hasUnread: false),
            PaneTabStripCardSnapshot(id: "terminal-tests", title: "Tests", kind: .terminal, isReady: true, agentStatus: .needsInput, hasUnread: true),
            PaneTabStripCardSnapshot(id: "browser-docs", title: "SwiftUI documentation", kind: .mirroredBrowser, isReady: true, agentStatus: nil, hasUnread: false),
            PaneTabStripCardSnapshot(id: "local-browser:local", sourceID: "local", title: "iPhone Browser", kind: .localBrowser, isReady: true, agentStatus: nil, hasUnread: false),
            PaneTabStripCardSnapshot(id: "chat:chat-editor", sourceID: "chat-editor", title: "Agent chat", kind: .agentChat, boundTerminalID: "terminal-editor", isReady: true, agentStatus: .needsInput, hasUnread: false),
        ]
        guard attentionShelfEnabled else { return cards }
        return cards.filter(\.needsAttention)
            + cards.filter { !$0.needsAttention }
    }
}
#endif
