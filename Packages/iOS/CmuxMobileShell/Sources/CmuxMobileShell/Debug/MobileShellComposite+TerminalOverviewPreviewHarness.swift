#if DEBUG
import CmuxMobileShellModel

extension MobileShellComposite {
    /// Builds a connected preview store for terminal overview simulator screenshots.
    ///
    /// This is only used by the DEBUG `CMUX_UITEST_TERMINAL_OVERVIEW_PREVIEW`
    /// launch hook. It avoids real auth/pairing dependencies while exercising
    /// the same workspace, toolbar, and overview grid views as the app.
    public static func terminalOverviewPreviewHarnessStore() -> CMUXMobileShellStore {
        let store = preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        store.navigateToWorkspaceForDeeplink("workspace-main")
        store.terminalOverviewPreviewLinesByID = [
            "terminal-build": [
                "$ swift build --package-path Packages/iOS/CmuxMobileShell",
                "Building cmux-ios for iPhone simulator",
                "Compile Swift sources",
                "Install and launch cmux DEV",
                "Build succeeded",
            ],
            "terminal-agent": [
                "$ swift test --package-path Packages/iOS/CmuxMobileShell --filter MobileShellCompositePreviewTests",
                "Suite MobileShellCompositePreviewTests started",
                "overviewPreviewLinesUseRenderGridRows passed",
                "closeTerminalRemovesSelectedTerminalAndSelectsNeighbor passed",
                "Test run passed",
            ],
            "terminal-tui": [
                "LAZYGIT",
                "files branches log",
                "main feature branch",
                "A TerminalTabOverviewView.swift",
                "A TerminalTabOverviewCard.swift",
            ],
            "terminal-notes": [
                "$ rg terminal overview docs",
                "iOS Safari-style tab switcher",
                "grid previews, close buttons, and tab count",
            ],
        ]
        return store
    }
}
#endif
