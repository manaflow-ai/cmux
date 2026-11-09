#if os(iOS)
import CmuxMobileModel
import CmuxTabsKit
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// The Mac's New Tab rows, Clear Tab Name and Copy rows in the phone's page menu, and Duplicate
/// Workspace Without Browser Tabs (verify/parity-mac.md, Tabs and Workspaces).
@MainActor @Suite struct TerminalToolsParityTests {
    func make(_ backend: MockWorkspaceCreationBackend) -> (AppStore, WorkspaceTabsSource, WorkspaceCreator) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let creator = WorkspaceCreator(store: store, backend: backend)
        return (store, WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", creator: creator), creator)
    }

    @Test func newTabRowsOpenATabOfTheSameKindAtTheirPosition() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (_, source, _) = make(backend)
        let terminal = try #require(source.tabs.first { source.workspaceTab($0.id)?.kind == .terminal })
        let rows = source.pageMenu(for: terminal).flatMap { $0 }.map(\.title)
        for title in ["New Tab to the Right", "New Tab of the Same Kind", "New Tab at Start", "New Tab at End"] {
            #expect(rows.contains(title), "\(title) in \(rows)")
        }
        // The card's menu keeps the Mac's top tab rows only.
        #expect(!source.cardMenu(for: terminal).flatMap { $0 }.contains { $0.title == "New Tab at Start" })
        let count = source.tabs.count
        await source.newTab(besides: terminal.id, at: .start)
        #expect(backend.newTabs.map(\.besides) == [terminal.id])
        #expect(backend.newTabs.map(\.position) == [.start])
        #expect(source.tabs.count == count + 1)
        #expect(source.activeTabID == source.tabs.last?.id)
        #expect(source.pendingTabTitle == nil)
        backend.failNext = "pane is gone"
        await source.newTab(besides: terminal.id, at: .end)
        #expect(source.toastText?.hasPrefix("Couldn't") == true)
    }

    @Test func clearTabNameOnlyOnANamedTab() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source, _) = make(backend)
        let terminal = try #require(source.tabs.first { source.workspaceTab($0.id)?.kind == .terminal })
        #expect(!source.pageMenu(for: terminal).flatMap { $0 }.contains { $0.title == "Clear Tab Name" })
        let ws = try #require(store.workspaces.firstIndex { $0.id == "ws-cmux" })
        let index = try #require(store.workspaces[ws].tabs.firstIndex { $0.id == terminal.id })
        store.workspaces[ws].tabs[index].hasCustomName = true
        source.refreshTabs()
        let clear = try #require(source.pageMenu(for: terminal).flatMap { $0 }.first { $0.title == "Clear Tab Name" })
        clear.action()
        for _ in 0..<100 where backend.clearedNames.isEmpty { await Task.yield() }
        #expect(backend.clearedNames == [terminal.id])
    }

    @Test func copyRowsNeedTheMacsIDs() throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, source, _) = make(backend)
        let terminal = try #require(source.tabs.first { source.workspaceTab($0.id)?.kind == .terminal })
        let ws = try #require(store.workspaces.firstIndex { $0.id == "ws-cmux" })
        let index0 = try #require(store.workspaces[ws].tabs.firstIndex { $0.id == terminal.id })
        // No ids from the Mac: no Copy rows (never a row that copies nothing).
        store.workspaces[ws].tabs[index0].linkIDs = nil
        store.workspaces[ws].resourceID = nil
        source.refreshTabs()
        #expect(!source.pageMenu(for: terminal).flatMap { $0 }.contains { $0.title == "Copy Tab Link" })
        store.workspaces[ws].resourceID = "ws_0123456789abcdef0123456789abcdef"
        let index = try #require(store.workspaces[ws].tabs.firstIndex { $0.id == terminal.id })
        store.workspaces[ws].tabs[index].linkIDs = WorkspaceTab.LinkIDs(tab: "tab_ffeeddccbbaa99887766554433221100",
                                                                        pane: "pane_00112233445566778899aabbccddeeff")
        source.refreshTabs()
        let rows = source.pageMenu(for: terminal).flatMap { $0 }.map(\.title)
        for title in ["Copy Tab Link", "Copy Tab ID", "Copy Pane Link", "Copy Pane ID", "Copy IDs"] {
            #expect(rows.contains(title), "\(title) in \(rows)")
        }
    }

    @Test func duplicateWithoutBrowserTabs() async throws {
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let (store, _, creator) = make(backend)
        let ws = try #require(store.workspace(id: "ws-web"))
        creator.duplicate(ws, browsers: false)
        await creator.settle()
        #expect(backend.duplicated == ["ws-web"])
        #expect(backend.duplicatedWithoutBrowsers == ["ws-web"])
        creator.duplicate(ws)
        await creator.settle()
        #expect(backend.duplicatedWithoutBrowsers == ["ws-web"])
    }
}
#endif
