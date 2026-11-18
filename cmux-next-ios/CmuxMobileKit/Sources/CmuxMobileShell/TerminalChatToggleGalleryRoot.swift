#if DEBUG && os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxMobileWorkspaces
import CmuxTabsKit
import SwiftUI

/// The review gallery for where an agent terminal's Chat / Terminal swap lives (ask-1105ee4cc6):
/// one workspace with one Codex terminal, drawn by the production tabs chrome, terminal page and
/// page menu, on the mock terminal session. Launch with
/// `-cmux-mobile-terminal-chat-toggle-gallery`, plus
/// `-cmux-mobile-terminal-chat-toggle-variant menu|navbar|gesture`,
/// `-cmuxMobile.settings.terminalChatToggle YES` (argument domain: nothing is written) and
/// `-cmux-mobile-term-fake-codex-idle` for a Codex-like screen. `TerminalChatToggleVariantsCaptureUITests`
/// takes the shots.
public struct TerminalChatToggleGalleryRoot: View {
    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-terminal-chat-toggle-gallery")
    }

    @State private var source: WorkspaceTabsSource
    @State private var showingOverview = false

    public init() {
        var tab = WorkspaceTab(id: "toggle-gallery-codex", kind: .terminal, title: "codex",
                               subtitle: "~/Development/cmux", harness: "codex")
        tab.linkIDs = WorkspaceTab.LinkIDs(tab: "tab_" + String(format: "%032x", 17), pane: "pane_" + String(format: "%032x", 1),
                                           isPaneSelected: true, harnessSession: "toggle-gallery-session")
        let workspace = Workspace(id: "toggle-gallery-workspace", macID: "mac-studio", title: "cmux",
                                  directory: "~/Development/cmux", branch: "feat-cmux-next",
                                  tabs: [tab], lastActivityAt: Date(), activeTabID: tab.id)
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [workspace], feed: [], tabMemory: .inMemory())
        let terminal = GhosttyTerminalTabContent()
        terminal.mockDataEnabled = true
        terminal.frameStore = nil
        _source = State(initialValue: WorkspaceTabsSource(store: store, workspaceID: workspace.id, terminal: terminal))
    }

    public var body: some View {
        TabsView(source: source, isShowingOverview: $showingOverview)
            .tabsKitTheme(.mobile)
            .tint(CmuxMobileTheme.standard.colors.label.color)
            .accessibilityIdentifier("terminalChatToggleGallery")
    }
}
#endif
