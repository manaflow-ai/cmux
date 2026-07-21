#if DEBUG
import CMUXMobileCore
import CmuxMobileShellModel

enum SurfaceSwitcherPreviewFixture {
    static let activeTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-8")
    static let activeBrowserStreamID = "browser-stream-7"

    static func value(
        terminalCount: Int = 8,
        browserStreamCount: Int = 7,
        includeChat: Bool = true,
        includeLocalBrowser: Bool = false,
        activeBrowserStreamID: String? = Self.activeBrowserStreamID
    ) -> TerminalPickerMenuValue {
        let terminals = makeTerminals(count: terminalCount)
        return TerminalPickerMenuValue(
            liveTerminals: terminals,
            snapshotRows: terminals.map(TerminalPickerMenuRow.init),
            selectedID: terminals.contains(where: { $0.id == activeTerminalID }) ? activeTerminalID : terminals.first?.id,
            canCreateWorkspace: true,
            isChatMode: false,
            chatDestination: includeChat ? chatDestination : nil,
            localBrowserDestination: includeLocalBrowser ? localBrowserDestination : nil,
            browserStreamRows: makeBrowserRows(count: browserStreamCount),
            supportsBrowserStream: true,
            activeBrowserStreamPanelID: activeBrowserStreamID,
            browserRefreshState: .idle
        )
    }

    static let actions = TerminalPickerMenuActions(
        preparePresentation: {},
        selectTerminal: { _ in },
        createTerminal: {},
        openBrowser: {},
        selectBrowserStream: { _ in },
        openChat: { _ in },
        openLocalBrowser: {},
        retryBrowserStreamRefresh: {}
    )

    private static let chatDestination = SurfaceSwitcherDestination(
        kind: .chat("agent-chat-main"),
        title: "Agent Chat",
        subtitle: "Pinned session",
        systemImage: "bubble.left.and.bubble.right",
        accessibilityIdentifier: "MobileAgentChatMenuItem-agent-chat-main"
    )

    private static let localBrowserDestination = SurfaceSwitcherDestination(
        kind: .localBrowser("phone-browser-main"),
        title: "Phone Browser",
        subtitle: "docs.cmux.dev",
        systemImage: "globe",
        accessibilityIdentifier: "MobileLocalBrowserMenuItem-phone-browser-main"
    )

    private static func makeTerminals(count: Int) -> [MobileTerminalPreview] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            let suffix = index == 8
                ? "Active build log with a deliberately long title"
                : "Terminal \(index)"
            return MobileTerminalPreview(id: "terminal-\(index)", name: suffix)
        }
    }

    private static func makeBrowserRows(count: Int) -> [BrowserStreamPickerRow] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            BrowserStreamPickerRow(
                MobileBrowserPanelDescriptor(
                    panelID: "browser-stream-\(index)",
                    workspaceID: "workspace-preview",
                    url: "https://preview-\(index).cmux.dev",
                    title: index == 7 ? "Mac Browser Preview" : "Browser \(index)",
                    pageWidth: 1200,
                    pageHeight: 800,
                    canGoBack: index > 1,
                    canGoForward: false,
                    isLoading: index == 3
                )
            )
        }
    }
}
#endif
