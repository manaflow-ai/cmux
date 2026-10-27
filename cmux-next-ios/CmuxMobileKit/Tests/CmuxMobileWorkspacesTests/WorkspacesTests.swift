import CmuxMobileModel
import Foundation
import Observation
import Testing
@testable import CmuxMobileWorkspaces

@Suite struct RelativeStampTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func compactUnits() {
        let stamp = RelativeStamp(now: now)
        #expect(stamp.string(for: now.addingTimeInterval(-20)) == "now")
        #expect(stamp.string(for: now.addingTimeInterval(-4 * 60)) == "4m")
        #expect(stamp.string(for: now.addingTimeInterval(-3 * 3600)) == "3h")
        #expect(stamp.string(for: now.addingTimeInterval(-2 * 86_400)) == "2d")
    }

    @Test func presenceLine() {
        let stamp = RelativeStamp(now: now)
        #expect(stamp.presence(isOnline: true, lastSeenAt: nil) == "Online")
        #expect(stamp.presence(isOnline: false, lastSeenAt: now.addingTimeInterval(-7200)) == "Last seen 2h ago")
        #expect(stamp.presence(isOnline: false, lastSeenAt: nil) == "Offline")
    }
}

#if os(iOS)
import CmuxMobileBrowserStream
import CmuxTabsKit
import SwiftUI

@MainActor @Suite struct WorkspaceTabsSourceTests {
    func make(_ memory: [String: String] = [:], backend: (any WorkspaceCreationBackend)? = MockWorkspaceCreationBackend(latency: .zero))
        -> (AppStore, WorkspaceTabsSource) {
        let store = AppStore.mock(tabMemory: .inMemory(memory))
        let creator = backend.map { WorkspaceCreator(store: store, backend: $0) }
        return (store, WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", creator: creator))
    }

    /// N2/A1: a shell tab running `sleep` (title "zsh") asks before its close kills it.
    @Test func closingATabWithARunningProgramAsks() async throws {
        let (store, source) = make(backend: ProgramsBackend(programs: ["sleep"]))
        let close = Task { await source.close("t-zsh") }
        for _ in 0..<200 where source.pendingClose == nil { await Task.yield() }
        let pending = try #require(source.pendingClose)
        #expect(pending.title == "Close \u{201C}zsh\u{201D}?")
        #expect(pending.message == "Still running: sleep.")
        source.resolvePendingClose(false)
        #expect(await close.value == false)
        #expect(store.workspaces.first { $0.id == "ws-cmux" }?.tabs.contains { $0.id == "t-zsh" } == true)
    }

    @Test func closingAnIdleShellDoesNotAsk() async {
        let (_, source) = make(backend: ProgramsBackend(programs: []))
        #expect(await source.close("t-zsh") == true)
        #expect(source.pendingClose == nil)
    }

    @Test func aCloseTheMacRefusesKeepsTheTab() async {
        let refusing = MockWorkspaceCreationBackend(latency: .zero)
        let (_, source) = make(backend: refusing)
        refusing.failNext = "tab is busy"
        let closed = await source.close("t-zsh")
        #expect(!closed)
        #expect(source.tabs.map(\.id) == ["t-claude", "t-zsh", "t-docs"])
        // One short line; the Mac's reason goes to the log, not the toast.
        #expect(source.toastText?.hasPrefix("Couldn't close") == true)
        #expect(source.toastText?.contains("tab is busy") == false)
    }

    @Test func aRefusedNewTabAddsNothing() async {
        let refusing = MockWorkspaceCreationBackend(latency: .zero)
        let (_, source) = make(backend: refusing)
        refusing.failNext = "no pane"
        let id = await source.requestTab(source.newTabOptions.first { $0.id == "terminal" }!)
        #expect(id == nil)
        #expect(source.tabs.count == 3)
        #expect(source.toastText?.hasPrefix("Couldn't open a terminal on") == true)
        #expect(source.toastText?.contains("no pane") == false)
    }

    /// User report (build 38484): + then New Claude Chat made the grid reflow around a
    /// placeholder card, and a refusal snapped it back. Pending, then refused, the tab
    /// list and every card label stay exactly as they were.
    @Test func aPendingThenRefusedNewTabLeavesTheGridUntouched() async {
        let refusing = MockWorkspaceCreationBackend(latency: .milliseconds(50))
        let (_, source) = make(backend: refusing)
        refusing.failNext = "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
        let before = source.tabs.map { [$0.id, $0.title, $0.subtitle ?? ""] }
        let option = source.newTabOptions.first { $0.id == "agent" }!
        // TabsKit gets no tab back, so its placeholder never stays; the request runs here.
        let returned = await source.createTab(option)
        #expect(returned == nil)
        #expect(source.pendingTabTitle == option.title)
        #expect(source.tabs.map { [$0.id, $0.title, $0.subtitle ?? ""] } == before)
        // A second + while one is pending does nothing.
        #expect(await source.createTab(option) == nil)
        for _ in 0..<200 where source.pendingTabTitle != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(source.pendingTabTitle == nil)
        #expect(source.openedTab == nil)
        #expect(source.tabs.map { [$0.id, $0.title, $0.subtitle ?? ""] } == before)
        #expect(source.toastText?.hasSuffix("doesn't allow agent chats in this folder from your iPhone yet.") == true)
    }

    /// User report 2026-10-14: GUI sessions must open model-agnostic, as the Mac's New Agent
    /// Chat (its default agent), never one "New Claude Chat" per harness; another agent or
    /// model is one step away (New Agent Chat With…).
    @Test func agentChatsAreOneModelAgnosticEntry() {
        let (_, source) = make()
        let titles = source.newTabOptions.map(\.title)
        #expect(titles == ["New Agent Chat", "New Agent Chat With…", "New Terminal", "New Browser Tab"])
        #expect(!titles.contains { $0.contains("Claude") || $0.contains("Codex") })
        #expect(WorkspaceTabsSource.kind(of: source.newTabOptions[0]) == .agentChat)
    }

    @Test func newAgentChatWithOpensTheChooser() async throws {
        let (_, source) = make()
        let count = source.tabs.count
        _ = await source.createTab(try #require(source.newTabOptions.first { $0.title == "New Agent Chat With…" }))
        #expect(source.choosingAgent)
        #expect(source.pendingTabTitle == nil)
        #expect(source.tabs.count == count)
        let catalog = try? await source.agentCatalog()
        #expect(catalog?.defaultChoice?.id == "claude")
        #expect(catalog?.harness("codex")?.unavailableReason == AgentCatalog.refusedReason)
        // Start Chat with another model: one chat, its harness and model in the request.
        let start = AgentChatStart(harness: "claude", model: "sonnet")
        #expect(WorkspaceTabsSource.kind(of: WorkspaceTabsSource.option(.agent(start))) == .agent(start))
        source.startAgentChat(start)
        #expect(!source.choosingAgent)
        #expect(source.pendingTabTitle == "New Agent Chat")
        for _ in 0..<200 where source.openedTab == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(source.tabs.count == count + 1)
    }

    /// User report 2026-10-14: no browser tabs from the phone, with no word why (an older
    /// Mac that does not stream them). The entry stays, and a tap says why.
    @Test func aKindTheMacCantOpenStaysWithItsReason() async throws {
        let older = MockWorkspaceCreationBackend(latency: .zero)
        older.kinds = [.agentChat, .terminal]
        older.unavailable = [(.browser, "Update cmux on your Mac to open browser tabs from your phone.")]
        let (_, source) = make(backend: older)
        let browser = try #require(source.newTabOptions.first { $0.title == "New Browser Tab" })
        #expect(browser.id.hasPrefix("unavailable:"))
        let count = source.tabs.count
        _ = await source.createTab(browser)
        #expect(source.pendingTabTitle == nil)
        #expect(source.tabs.count == count)
        #expect(source.toastText?.hasPrefix("Update cmux on ") == true)
        #expect(source.toastText?.contains("your Mac") == false)
        // Agents not connected yet: the entry stays, the chooser does not.
        older.kinds = [.terminal]
        older.unavailable = [(.agentChat, "Agents on this Mac aren't connected yet. Try again in a moment.")]
        #expect(source.newTabOptions.map(\.title) == ["New Terminal", "New Agent Chat"])
    }

    /// Parity with the Mac's Rename Tab…, Duplicate Tab and tab drag (verify/parity-mac.md).
    @Test func renameDuplicateAndMoveTabs() async {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        let terminal = source.tabs[1]
        // The Mac's tab menu: Rename Tab…, Pin Tab, Duplicate Tab | its group rows (TabsKit adds
        // Close Tab and Close Other Tabs); its More's moves are in the page menu.
        #expect(source.cardMenu(for: terminal).map { $0.map(\.title) } == [["Rename Tab…", "Pin Tab", "Duplicate Tab"], ["New Tab Group"]])
        let page = source.pageMenu(for: terminal).flatMap { $0 }.map(\.title)
        #expect(page.contains("Move Tab to Workspace…") && page.contains("Move Tab to New Workspace"))
        #expect(source.pageMenu(for: source.tabs[0]).flatMap { $0 }.contains { $0.title == "Rename Tab…" })
        // A chat duplicates too (a second tab of the same chat, as on the Mac).
        #expect(source.pageMenu(for: source.tabs[0]).flatMap { $0 }.contains { $0.title == "Duplicate Tab" })
        source.startRename(terminal.id)
        #expect(source.renamingTab?.id == terminal.id)
        await source.rename(terminal.id, to: "build")
        #expect(source.renamingTab == nil)
        #expect(store.workspace(id: "ws-cmux")?.tabs[1].title == "build")
        backend.failNext = "no such surface"
        await source.rename(terminal.id, to: "other")
        #expect(store.workspace(id: "ws-cmux")?.tabs[1].title == "build")
        #expect(source.toastText == "Couldn't rename build.")

        let count = source.tabs.count
        await source.duplicate(terminal.id)
        #expect(source.tabs.count == count + 1)
        #expect(source.activeTabID == source.tabs.last?.id)
        #expect(source.pendingTabTitle == nil)

        #expect(source.supportsReordering)
        let order = source.tabs.map(\.id)
        source.moveTab(order[0], to: 2)
        #expect(source.tabs.map(\.id) == [order[1], order[2], order[0]] + order.dropFirst(3))
        // The Mac's answer to the first move arrives before the next one is tried.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(source.tabs.map(\.id) == [order[1], order[2], order[0]] + order.dropFirst(3))
        backend.failNext = "pane is gone"
        source.moveTab(order[1], to: 1)
        for _ in 0..<100 where source.tabs.first?.id != order[1] { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(source.tabs.first?.id == order[1])
        #expect(source.toastText?.hasPrefix("Couldn't move") == true)
    }

    /// A page's link that opens a new tab or window (`rb.open_tab`): a browser tab beside the
    /// page, shown at once (a background tab stays behind with a toast); one the Mac refuses
    /// says why and gives the page no tab. The browser page menu has Hard Reload and Open in
    /// Safari only for a page that can do them.
    @Test func aPageLinkOpensABrowserTabBesideIt() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        let count = source.tabs.count
        let shown = RemoteBrowserOpenTab(request: 1, url: "https://example.com/next", disposition: .foregroundTab, userGesture: true)
        let id = try #require(await source.openLinkTab(shown, from: "t-docs"))
        #expect(source.tabs.count == count + 1)
        #expect(store.workspace(id: "ws-cmux")?.tabs.last?.url?.absoluteString == "https://example.com/next")
        #expect(source.activeTabID == id && source.openedTab == id && source.pendingTabTitle == nil)

        source.activate("t-docs")
        let behind = RemoteBrowserOpenTab(request: 2, url: "https://example.com/b", disposition: .backgroundTab, userGesture: true)
        let other = try #require(await source.openLinkTab(behind, from: "t-docs"))
        #expect(source.activeTabID == "t-docs" && other != id && source.toastText == "Opened in a new tab.")

        backend.failNext = "no such pane"
        #expect(await source.openLinkTab(shown, from: "t-docs") == nil)
        #expect(source.tabs.count == count + 2)
        #expect(source.toastText?.hasPrefix("Couldn't") == true)

        let docs = try #require(source.tabs.first { $0.id == "t-docs" })
        let rows = source.pageMenu(for: docs).flatMap { $0 }.map(\.title)
        // A local web view (no Mac stream) has no Hard Reload; its web address opens in Safari.
        #expect(rows.contains("Open in Safari") && !rows.contains("Hard Reload"))
    }

    /// Parity round 2: Move Tab to Workspace… and Move Tab to New Workspace (the Mac's titles).
    @Test func moveTabToAnotherWorkspace() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        // Only workspaces of the same Mac are destinations.
        #expect(source.otherWorkspaces.map(\.id).contains("ws-web"))
        #expect(!source.otherWorkspaces.contains { $0.macID != "mac-studio" || $0.id == "ws-cmux" })
        let zsh = try #require(source.tabs.first { $0.id == "t-zsh" })
        source.pageMenu(for: zsh).flatMap { $0 }.first { $0.title == "Move Tab to Workspace…" }?.action()
        #expect(source.movingTab?.id == "t-zsh")
        let webCount = store.workspace(id: "ws-web")?.tabs.count ?? 0
        await source.move("t-zsh", to: "ws-web")
        #expect(source.movingTab == nil)
        #expect(!source.tabs.contains { $0.id == "t-zsh" })
        #expect(store.workspace(id: "ws-web")?.tabs.count == webCount + 1)
        #expect(source.toastText == "Moved zsh to cmux.com.")
        // A refusal keeps the tab where it was, with one short line.
        backend.failNext = "unknown surface"
        await source.move("t-docs", to: nil)
        #expect(source.tabs.contains { $0.id == "t-docs" })
        #expect(source.toastText == "Couldn't move Swift docs.")
    }

    /// The Mac: "Home's tabs stay in Home." A Home tab offers no Move Tab to New Workspace;
    /// Move Tab to Workspace… stays, as on the Mac.
    @Test func homeTabsStayInHome() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        let index = try #require(store.workspaces.firstIndex { $0.id == "ws-cmux" })
        store.workspaces[index].isHome = true
        let zsh = try #require(source.tabs.first { $0.id == "t-zsh" })
        let titles = (source.pageMenu(for: zsh) + source.cardMenu(for: zsh)).flatMap { $0 }.map(\.title)
        #expect(titles.contains("Move Tab to Workspace…") && !titles.contains("Move Tab to New Workspace"))
        #expect(titles.contains("Pin Tab"))
        await source.move("t-zsh", to: nil)
        #expect(source.tabs.contains { $0.id == "t-zsh" })
        #expect(source.toastText == "Home's tabs stay in Home.")
        await source.move("t-zsh", to: "ws-web")
        #expect(!source.tabs.contains { $0.id == "t-zsh" })
    }

    @Test func pinAndUnpinTab() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        await source.setPinned("t-zsh", true)
        #expect(store.workspace(id: "ws-cmux")?.tabs.first { $0.id == "t-zsh" }?.isPinned == true)
        let zsh = try #require(source.tabs.first { $0.id == "t-zsh" })
        #expect(zsh.systemImage == "pin.fill")
        let titles = source.cardMenu(for: zsh).flatMap { $0 }.map(\.title)
        #expect(titles.contains("Unpin Tab") && !titles.contains("Pin Tab"))
        // The Mac refuses grouping a pinned tab: no New Tab Group on it.
        #expect(!titles.contains("New Tab Group"))
        backend.failNext = "no such surface"
        await source.setPinned("t-zsh", false)
        #expect(store.workspace(id: "ws-cmux")?.tabs.first { $0.id == "t-zsh" }?.isPinned == true)
        #expect(source.toastText?.hasPrefix("Couldn't unpin") == true)
    }

    /// Restart Shell Here (the Mac's dead-tab overlay and tab menu row): only on a terminal
    /// whose shell ended; it asks the Mac to start the tab's shell again.
    @Test func restartShellOnlyOnAnEndedShell() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        let live = try #require(source.tabs.first { $0.id == "t-zsh" })
        #expect(!source.pageMenu(for: live).flatMap { $0 }.map(\.title).contains(WorkspaceTabsSource.restartShellTitle))
        await source.restartShell("t-zsh")
        #expect(backend.restartedShells.isEmpty)
        store.updateTab("t-zsh", in: "ws-cmux") { $0.shellEnded = true }
        let ended = try #require(source.tabs.first { $0.id == "t-zsh" })
        #expect(source.pageMenu(for: ended).flatMap { $0 }.map(\.title).first == WorkspaceTabsSource.restartShellTitle)
        await source.restartShell("t-zsh")
        #expect(backend.restartedShells == ["t-zsh"])
        backend.failNext = "tab-not-dead"
        await source.restartShell("t-zsh")
        #expect(source.toastText?.hasPrefix("Couldn't restart") == true)
    }

    /// Reopen / Delete Saved Tab Group… (the Mac's palette rows, in the page menu): the
    /// chooser lists the Mac's saved groups; an open one is not reopened again.
    @Test func savedTabGroupsFromThePageMenu() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (_, source) = make(backend: backend)
        let zsh = try #require(source.tabs.first { $0.id == "t-zsh" })
        let titles = source.pageMenu(for: zsh).flatMap { $0 }.map(\.title)
        #expect(titles.contains("Reopen Saved Tab Group…") && titles.contains("Delete Saved Tab Group…"))
        #expect(!source.cardMenu(for: zsh).flatMap { $0 }.map(\.title).contains("Reopen Saved Tab Group…"))

        // None saved: one line, no chooser.
        await source.openSavedGroups(.reopen, from: "t-zsh")
        #expect(source.savedGroupsChooser == nil)
        #expect(source.toastText?.contains("No saved tab groups") == true)

        let release = SavedTabGroup(id: "saved_a", name: "Release", color: "orange", terminals: 2)
        let open = SavedTabGroup(id: "saved_b", name: "Docs", color: "green", browsers: 1, isOpen: true)
        backend.savedGroups = [release, open]
        await source.openSavedGroups(.reopen, from: "t-zsh")
        #expect(source.savedGroupsChooser?.groups == [release, open])
        #expect(source.savedGroupsChooser?.tab.id == "t-zsh")

        await source.reopenSaved(release, besides: "t-zsh")
        #expect(source.savedGroupsChooser == nil)
        #expect(backend.reopenedGroups.map { $0.saved } == ["saved_a"])
        #expect(backend.reopenedGroups.map { $0.besides } == ["t-zsh"])
        #expect(source.toastText == "Reopened Release.")

        // Already open: the Mac's refusal, and nothing sent.
        await source.reopenSaved(open, besides: "t-zsh")
        #expect(backend.reopenedGroups.count == 1)
        #expect(source.toastText == SavedTabGroupAction.alreadyOpen)

        await source.openSavedGroups(.delete, from: "t-zsh")
        #expect(source.savedGroupsChooser?.action == .delete)
        await source.deleteSaved(release)
        #expect(backend.savedGroups.map(\.id) == ["saved_b"])
        #expect(source.toastText == "Deleted Release.")

        backend.failNext = "saved_tab_group saved_x not found"
        await source.deleteSaved(SavedTabGroup(id: "saved_x"))
        #expect(source.toastText == SavedTabGroupAction.gone)
    }

    @Test func tabGroupsFromTheTabMenu() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        func tab(_ id: String) -> WorkspaceTab? { store.workspace(id: "ws-cmux")?.tabs.first { $0.id == id } }
        // New Tab Group on one tab, then the Mac's list names it.
        await source.editGroup(.create, "t-zsh")
        #expect(backend.groupEdits == [.create])
        store.updateTab("t-zsh", in: "ws-cmux") { $0.group = WorkspaceTab.TabGroupRef(id: "tgrp_1", name: "", color: "red") }
        // Another tab can join it (Add Tab to Group…).
        let docs = try #require(source.tabs.first { $0.id == "t-docs" })
        let docsMenu = source.cardMenu(for: docs).flatMap { $0 }.map(\.title)
        #expect(docsMenu.contains("New Tab Group") && docsMenu.contains("Add Tab to Group…"))
        #expect(source.groups(besides: try #require(tab("t-docs"))).map(\.id) == ["tgrp_1"])
        await source.editGroup(.add(group: "tgrp_1"), "t-docs")
        #expect(tab("t-docs")?.group?.id == "tgrp_1")
        // A member's menu: Remove Tab from Group and the group's own actions.
        let zsh = try #require(source.tabs.first { $0.id == "t-zsh" })
        let zshMenu = source.cardMenu(for: zsh).flatMap { $0 }.map(\.title)
        #expect(zshMenu.contains("Remove Tab from Group") && zshMenu.contains("Tab Group: Red group…"))
        await source.editGroup(.rename("Review"), "t-zsh")
        #expect(tab("t-docs")?.group?.name == "Review")
        await source.editGroup(.save, "t-zsh")
        #expect(tab("t-zsh")?.group?.isSaved == true)
        // A refusal puts membership back.
        backend.failNext = "no such group"
        await source.editGroup(.remove, "t-docs")
        #expect(tab("t-docs")?.group?.id == "tgrp_1")
        #expect(source.toastText == "Remove Tab from Group didn't work on Aziz's Mac Studio.")
        await source.editGroup(.ungroup, "t-zsh")
        #expect(tab("t-zsh")?.group == nil && tab("t-docs")?.group == nil)
        // Close Tab Group closes every member once the Mac did.
        store.updateTab("t-zsh", in: "ws-cmux") { $0.group = WorkspaceTab.TabGroupRef(id: "tgrp_2") }
        store.updateTab("t-docs", in: "ws-cmux") { $0.group = WorkspaceTab.TabGroupRef(id: "tgrp_2") }
        await source.editGroup(.close, "t-zsh")
        #expect(tab("t-zsh") == nil && tab("t-docs") == nil)
        #expect(backend.groupEdits.last == .close)
    }

    @Test func forkArchiveAndDuplicateAChat() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source) = make(backend: backend)
        let claude = try #require(source.tabs.first { $0.id == "t-claude" })
        let menu = source.pageMenu(for: claude).flatMap { $0 }.map(\.title)
        #expect(menu.contains("Fork") && menu.contains("Archive") && menu.contains("Duplicate Tab"))
        let count = source.tabs.count
        await source.fork("t-claude")
        #expect(source.tabs.count == count + 1)
        #expect(source.activeTabID == source.tabs.last?.id && source.openedTab == source.tabs.last?.id)
        // acpmux's refusal of a Mac-started Claude chat, in its own words.
        backend.failNext = nil
        let refusing = RefusingForkBackend()
        let (_, refused) = make(backend: refusing)
        await refused.fork("t-claude")
        // In the Mac's own words, naming the Mac ("your Mac" reads as its name on the phone).
        #expect(refused.toastText == "This chat runs with Aziz's Mac Studio's Claude permissions. Start a new chat from this device to control it remotely.")
        await source.archive("t-claude")
        #expect(backend.archived == ["t-claude"])
        #expect(store.workspace(id: "ws-cmux")?.tabs.contains { $0.id == "t-claude" } == false)
    }

    /// Finding 4: a browser tab on about:blank has no address; the field (and VoiceOver) reads
    /// its placeholder, never "about:blank".
    @Test func aBlankBrowserTabHasNoAddress() throws {
        let (store, source) = make()
        store.appendTab(WorkspaceTab(id: "t-blank", kind: .browser, title: "New Tab", url: URL(string: "about:blank")), to: "ws-cmux")
        let blank = try #require(source.tabs.first { $0.id == "t-blank" })
        #expect(blank.address.label == "Search or enter website")
        #expect(blank.subtitle.isEmpty)
    }

    @Test func aConfirmedNewTabOpensOnceTheMacListsIt() async {
        let (_, source) = make(backend: MockWorkspaceCreationBackend(latency: .milliseconds(50)))
        let count = source.tabs.count
        _ = await source.createTab(source.newTabOptions.first { $0.id == "terminal" }!)
        #expect(source.tabs.count == count)
        for _ in 0..<200 where source.openedTab == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(source.tabs.count == count + 1)
        #expect(source.openedTab == source.tabs.last?.id)
        #expect(source.activeTabID == source.tabs.last?.id)
    }

    @Test func withoutAMacNoTabsAreMade() async {
        let (_, source) = make(backend: nil)
        #expect(source.newTabOptions.isEmpty)
        let id = await source.requestTab(TabsKitNewTabOption(id: "terminal", title: "New Terminal", systemImage: "apple.terminal", kind: .terminal))
        #expect(id == nil)
        #expect(source.tabs.count == 3)
        let closed = await source.close("t-zsh")
        #expect(!closed)
        #expect(source.tabs.count == 3)
    }

    @Test func opensOnTheLastTabUsedOnThisDevice() {
        let (_, source) = make(["ws-cmux": "t-docs"])
        #expect(source.activeTabID == "t-docs")
        let (_, fresh) = make()
        #expect(fresh.activeTabID == "t-claude")
    }

    @Test func everyActivationIsRemembered() {
        let (store, source) = make()
        source.activate("t-zsh")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-zsh")
        // Reopening the workspace starts there.
        #expect(WorkspaceTabsSource(store: store, workspaceID: "ws-cmux").activeTabID == "t-zsh")
    }

    @Test func closingTheActiveTabActivatesItsNeighbor() async {
        let (store, source) = make()
        source.activate("t-zsh")
        let closed = await source.close("t-zsh")
        #expect(closed)
        #expect(source.activeTabID == "t-docs")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-docs")
        #expect(source.tabs.map(\.id) == ["t-claude", "t-docs"])
    }

    @Test func newTabsGoLastAndBecomeActive() async {
        let (store, source) = make()
        let option = source.newTabOptions.first { $0.id == "terminal" }!
        let id = await source.requestTab(option)
        #expect(source.tabs.last?.id == id)
        #expect(source.activeTabID == id)
        #expect(store.lastTabByWorkspace["ws-cmux"] == id)
    }

    @Test func tabsMapToTabsKitChrome() {
        let (_, source) = make()
        let tabs = Dictionary(uniqueKeysWithValues: source.tabs.map { ($0.id, $0) })
        #expect(tabs["t-claude"]?.kind == TabsKitTabKind("agent"))
        #expect(tabs["t-claude"]?.features == [.history, .pageMenu])
        // No page history: back leaves the workspace, so it is enabled.
        #expect(tabs["t-claude"]?.navigation.canGoBack == true)
        #expect(tabs["t-zsh"]?.kind == .terminal)
        #expect(tabs["t-zsh"]?.statusBarStyle == .lightContent)
        #expect(tabs["t-docs"]?.kind == .web)
        #expect(tabs["t-docs"]?.features == .web)
        if case .url(let display, _, _)? = tabs["t-docs"]?.address {
            #expect(display == "developer.apple.com")
        } else {
            Issue.record("browser tab should show its host")
        }
    }

    @Test func backLeavesTheWorkspaceWithoutPageHistory() {
        let (_, source) = make()
        var left = 0
        source.exit = { left += 1 }
        source.goBack("t-claude")
        source.goBack("t-docs")
        #expect(left == 2)
    }
}
/// A terminal content that adds its own page menu actions and records grid prep.
@MainActor final class RecordingTerminalContent: TerminalTabContent {
    var prepared: [String] = []
    var performed: [String] = []

    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView { AnyView(EmptyView()) }
    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView { AnyView(EmptyView()) }
    func overviewWillAppear(active tab: WorkspaceTab) { prepared.append(tab.id) }
    var focused: [String] = []
    func focusInput(for tab: WorkspaceTab, in workspace: Workspace) { focused.append(tab.id) }
    func actions(for tab: WorkspaceTab, in workspace: Workspace) -> [TerminalTabAction] {
        [TerminalTabAction(title: "Files and Links", systemImage: "folder") { self.performed.append("files") },
         TerminalTabAction(title: "Paste", systemImage: "doc.on.clipboard") { self.performed.append("paste") }]
    }
}

@MainActor @Suite struct TerminalTabEmbeddingTests {
    @Test func terminalActionsLeadThePageMenu() throws {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "t-zsh"]))
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        let kit = try #require(source.tabs.first { $0.id == "t-zsh" })
        let groups = source.pageMenu(for: kit)
        #expect(groups.first?.map(\.title) == ["Files and Links", "Paste"])
        // Design/terminal P1: Back leaves the workspace, so no "All Workspaces".
        #expect(groups.map { $0.map(\.title) } == [["Files and Links", "Paste"], ["Copy Directory"], ["Close Tab"]])
        groups.first?.first?.action()
        #expect(content.performed == ["files"])
    }

    /// Round 2: new chats and terminals open with the keyboard up; existing ones do not.
    @Test func newWorkspacesAndTabsOpenReadyToType() async throws {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "t-claude"]))
        // Opening an existing workspace leaves the keyboard down.
        let existing = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        existing.pageAppeared("t-claude")
        #expect(existing.surface("t-claude").composerFocused == false)
        // A workspace this phone just created opens focused (agent chat).
        store.requestFocusOnOpen("ws-cmux")
        let created = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content,
                                          creator: WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero)))
        created.pageAppeared("t-claude")
        #expect(created.surface("t-claude").composerFocused)
        // A new terminal tab raises the keyboard on its composer.
        let id = await created.requestTab(try #require(created.newTabOptions.first { $0.id == "terminal" }))
        #expect(content.focused == [try #require(id)])
    }

    /// verify/e2e-matrix.md #4: the navigation destination builds a
    /// `WorkspaceScreen` on every update it re-runs; building one (and its
    /// source) must not write the store, or the update re-invalidates
    /// itself forever. The writes happen once, when the screen appears.
    @Test func buildingAWorkspaceScreenWritesNothing() throws {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "gone"]))
        store.requestFocusOnOpen("ws-cmux")
        let notified = ObservedChanges()
        withObservationTracking { Self.readAll(store) } onChange: { notified.count += 1 }
        var source: WorkspaceTabsSource?
        for _ in 0..<5 {
            _ = WorkspaceScreen(store: store, workspaceID: "ws-cmux", terminal: content)
            source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        }
        #expect(notified.count == 0)
        let opened = try #require(source)
        #expect(opened.activeTabID == "t-claude")
        // Appearing remembers the tab and consumes the focus request, once.
        opened.opened()
        #expect(notified.count == 1)
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-claude")
        #expect(!store.wantsFocusOnOpen("ws-cmux"))
        opened.pageAppeared("t-claude")
        #expect(opened.surface("t-claude").composerFocused)
    }

    /// Runs like a SwiftUI destination update: again while an observation
    /// installed before the run saw a change.
    @Test func aDestinationUpdateSettles() {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory())
        var runs = 0
        let dirty = ObservedChanges()
        dirty.count = 1
        while dirty.count > 0, runs < 20 {
            dirty.count = 0
            runs += 1
            withObservationTracking { Self.readAll(store) } onChange: { dirty.count += 1 }
            _ = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content).activeTabID
        }
        #expect(runs == 1)
    }

    final class ObservedChanges: @unchecked Sendable {
        var count = 0
    }

    static func readAll(_ store: AppStore) {
        _ = store.workspaces
        _ = store.lastTabByWorkspace
        _ = store.focusOnOpenWorkspaceIDs
        _ = store.workspaceAliases
        _ = store.pendingWorkspaceIDs
        _ = store.teams
        _ = store.seenAt
    }

    @Test func gridOpeningPreparesTheActiveTerminalCard() {
        let content = RecordingTerminalContent()
        let store = AppStore.mock(tabMemory: .inMemory(["ws-cmux": "t-zsh"]))
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", terminal: content)
        source.overviewWillAppear()
        source.activate("t-claude")
        source.overviewWillAppear()
        #expect(content.prepared == ["t-zsh"])
    }
}
#endif

/// A Mac whose terminals run `programs` (`process-info`).
@MainActor final class ProgramsBackend: WorkspaceCreationBackend {
    let programs: [String]
    init(programs: [String]) { self.programs = programs }
    func canCreate(on macID: String) -> Bool { true }
    func options(on macID: String) -> WorkspaceCreationOptions { .basic }
    func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
    func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {}
    func runningPrograms(of tabs: [WorkspaceTab], in workspace: Workspace) async -> [String] { programs }
}

/// acpmux refuses a Web fork of a Claude chat the Mac started (D13) with this reason.
@MainActor final class RefusingForkBackend: WorkspaceCreationBackend {
    static let reason = "This chat runs with your Mac's Claude permissions. Start a new chat from this device to control it remotely."
    func canCreate(on macID: String) -> Bool { true }
    func options(on macID: String) -> WorkspaceCreationOptions { .basic }
    func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
    func canEditTabs(on macID: String) -> Bool { true }
    func forkAgentChat(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError(Self.reason, isForPerson: true)
    }
}
