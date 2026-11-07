import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

#if os(iOS)
import CmuxTabsKit

/// The phone's command palette (the Mac's Command Palette…, cmux#25834): its rows are the
/// menus' own items, picked rows run once the sheet is gone, and its searches reach every
/// workspace.
@MainActor @Suite(.serialized) struct CommandPaletteTests {
    func make(_ backend: MockWorkspaceCreationBackend = MockWorkspaceCreationBackend(latency: .zero),
              memory: [String: String] = ["ws-cmux": "t-zsh"]) -> (AppStore, WorkspaceTabsSource) {
        let store = AppStore.mock(tabMemory: .inMemory(memory))
        return (store, WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", creator: WorkspaceCreator(store: store, backend: backend)))
    }

    /// Every row of the tab's page and card menus and every + option is a palette row, once
    /// each; the palette's own menu row is not.
    @Test func rowsAreTheMenusOwnItems() throws {
        let (_, source) = make()
        let active = try #require(source.tabs.first { $0.id == source.activeTabID })
        let menu = Set((source.pageMenu(for: active) + source.cardMenu(for: active)).flatMap { $0 }.map(\.title))
        let titles = source.paletteActions().map(\.title)
        #expect(menu.contains(WorkspaceTabsSource.paletteTitle))
        #expect(!titles.contains(WorkspaceTabsSource.paletteTitle))
        #expect(menu.subtracting([WorkspaceTabsSource.paletteTitle]).isSubset(of: Set(titles)))
        #expect(Set(titles).count == titles.count)
        for option in source.newTabOptions { #expect(titles.contains(option.title)) }
        #expect(titles.contains(WorkspaceTabsSource.searchTabsTitle))
        #expect(titles.contains("Jump to Latest Unread") && titles.contains("Jump to Last Prompt"))
    }

    /// A picked row waits for the sheet's dismissal, then runs once.
    @Test func aPickedRowRunsAfterTheSheetCloses() throws {
        let (_, source) = make()
        source.openPalette()
        #expect(source.palette == .actions)
        let rename = try #require(source.paletteActions().first { $0.title == "Rename Tab…" })
        source.pick(rename)
        #expect(source.palette == nil)
        #expect(source.renamingTab == nil)
        source.paletteDismissed()
        #expect(source.renamingTab?.id == "t-zsh")
        source.renamingTab = nil
        source.paletteDismissed()
        #expect(source.renamingTab == nil)
    }

    /// A row that goes to another workspace runs in the tap, with the sheet closing (a page push
    /// made after the sheet was gone was dropped on the rig); the opened rows are the ones taken
    /// when the palette opened.
    @Test func aNavigationRowRunsInTheTap() throws {
        let (_, source) = make()
        var opened: Workspace?
        source.openWorkspace = { opened = $0 }
        source.openPalette()
        #expect(source.paletteActionRows.contains { $0.title == "Rename Tab…" })
        let hit = try #require(source.paletteTabs(matching: "bun dev").first)
        #expect(hit.navigates)
        source.pick(hit)
        #expect(source.palette == nil)
        #expect(opened?.id == "ws-web")
        opened = nil
        source.paletteDismissed()
        #expect(opened == nil)
    }

    /// Search Tabs reaches every workspace, this one's first; a tab elsewhere opens its own
    /// workspace on that tab.
    @Test func searchTabsCoversEveryWorkspace() throws {
        let (store, source) = make()
        let all = source.paletteTabs(matching: "")
        #expect(all.first?.id.hasPrefix("tab.ws-cmux.") == true)
        let hits = source.paletteTabs(matching: "bun dev")
        let hit = try #require(hits.first)
        #expect(hits.count == 1 && hit.id == "tab.ws-web.t-dev")
        #expect(source.paletteTabs(matching: "zsh", otherWorkspacesOnly: true).allSatisfy { !$0.id.hasPrefix("tab.ws-cmux.") })
        var opened: Workspace?
        source.openWorkspace = { opened = $0 }
        hit.run()
        #expect(opened?.id == "ws-web")
        #expect(store.lastTabByWorkspace["ws-web"] == "t-dev")
        // A tab of this workspace is made active here.
        try #require(source.paletteTabs(matching: "Swift docs").first).run()
        #expect(source.activeTabID == "t-docs")
    }

    @Test func jumpsGoToTheMacsPlaceOrSayWhyNot() {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (_, source) = make(backend)
        var opened: Workspace?
        source.openWorkspace = { opened = $0 }
        source.jump(.unread)
        #expect(source.toastText == TabAttentionPlace.noUnread)
        backend.attention.unread = TabAttentionPlace(workspaceID: "ws-ios", tabID: "t-ios-build", at: Date())
        source.jump(.unread)
        #expect(opened?.id == "ws-ios")
        backend.attention.prompt = TabAttentionPlace(workspaceID: "ws-cmux", tabID: "t-claude", at: Date())
        source.jump(.lastPrompt)
        #expect(source.activeTabID == "t-claude")
    }

    /// New Tab from Text: a link opens as a link; otherwise the Mac's table, plus an explicit search.
    @Test func typedTextOffersWhatItOpens() {
        let (_, source) = make()
        #expect(source.paletteText("cmux://tab/tab_00000000000000000000000000000002").map(\.id) == ["link.open"])
        #expect(source.paletteText("!make test").map(\.id) == ["newTab.terminal"])
        #expect(source.paletteText("github.com").map(\.id) == ["newTab.address", "newTab.search"])
        #expect(source.paletteText("why is CI red").map(\.id) == ["newTab.chat", "newTab.search"])
        #expect(source.paletteText(" ").isEmpty)
    }

    /// A prompt opens a new agent chat on the Mac and goes to it.
    @Test func aPromptOpensANewChat() async throws {
        let (store, source) = make()
        let before = Set(store.workspace(id: "ws-cmux")!.tabs.map(\.id))
        try #require(source.paletteText("summarize the diff").first).run()
        #expect(source.pendingTabTitle == "New Agent Chat")
        for _ in 0..<200 where source.openedTab == nil { await Task.yield() }
        let opened = try #require(source.openedTab)
        #expect(!before.contains(opened))
        #expect(store.workspace(id: "ws-cmux")?.tabs.first { $0.id == opened }?.kind == .agent)
        #expect(source.activeTabID == opened)
    }

    /// Mute Chat Notifications is the chat menu's, phone-local, and reads Unmute once muted.
    @Test func muteIsAChatMenuRow() throws {
        let (_, source) = make()
        let list = ChatMuteList.shared
        let claude = try #require(source.tabs.first { $0.id == "t-claude" })
        let zsh = try #require(source.tabs.first { $0.id == "t-zsh" })
        #expect(!source.pageMenu(for: zsh).flatMap { $0 }.contains { $0.id == "agentChat.toggleNotificationMute" })
        let mute = try #require(source.pageMenu(for: claude).flatMap { $0 }.first { $0.id == "agentChat.toggleNotificationMute" })
        #expect(mute.title == "Mute Chat Notifications")
        mute.action()
        #expect(list.isMuted(mac: "mac-studio", session: "session-t-claude"))
        let unmute = try #require(source.pageMenu(for: claude).flatMap { $0 }.first { $0.id == "agentChat.toggleNotificationMute" })
        #expect(unmute.title == "Unmute Chat Notifications")
        unmute.action()
        #expect(!list.isMuted(mac: "mac-studio", session: "session-t-claude"))
    }
}
#endif
