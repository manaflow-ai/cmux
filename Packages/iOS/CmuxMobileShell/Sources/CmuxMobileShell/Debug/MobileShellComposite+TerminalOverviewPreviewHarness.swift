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
        store.terminalOverviewPreviewLinesByID = [
            "terminal-build": [
                "$ CMUX_SKIP_ZIG_BUILD=1 ./ios/scripts/reload.sh --tag issue-6347-ios-tab-overview",
                "Building cmux-ios for iPhone 17 simulator",
                "Compile Swift sources",
                "Install and launch dev.cmux.ios.issue-6347-ios-tab-overview",
                "Build succeeded",
            ],
            "terminal-agent": [
                "$ swift test --package-path Packages/iOS/CmuxMobileShell --filter MobileShellCompositePreviewTests",
                "Suite MobileShellCompositePreviewTests started",
                "overviewPreviewLinesUseRenderGridRows passed",
                "closeTerminalRemovesSelectedTerminalAndSelectsNeighbor passed",
                "Test run with 16 tests passed",
            ],
            "terminal-tui": [
                "LAZYGIT",
                "files branches log",
                "main issue-6347-ios-tab-overview",
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
