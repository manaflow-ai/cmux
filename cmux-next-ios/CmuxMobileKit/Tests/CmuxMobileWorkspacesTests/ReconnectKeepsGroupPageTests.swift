#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Leo, 2026-11-21: "i lost connection with cosmic gray or some s***... multiple issues to fix there".
/// A tab group page popped the moment its members were missing, which a reconnect's partial
/// resync does for a few seconds. It goes only when the group stays empty on a connected Mac.
@MainActor @Suite struct ReconnectKeepsGroupPageTests {
    static let group = WorkspaceTab.TabGroupRef(id: "g1", name: "Docs", color: "blue")

    /// "ws-cmux" on "mac-studio" with t-zsh and t-docs grouped.
    func make() -> (AppStore, WorkspaceTabsSource, GridTestClock, [WorkspaceTab]) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let index = store.workspaces.firstIndex { $0.id == "ws-cmux" }!
        for tab in 0..<store.workspaces[index].tabs.count where store.workspaces[index].tabs[tab].id != "t-claude" {
            store.workspaces[index].tabs[tab].group = Self.group
        }
        let full = store.workspaces[index].tabs
        let clock = GridTestClock()
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", clock: clock)
        return (store, source, clock, full)
    }

    func settle() async { for _ in 0..<64 { await Task.yield() } }

    func setTabs(_ store: AppStore, _ tabs: [WorkspaceTab]) {
        let index = store.workspaces.firstIndex { $0.id == "ws-cmux" }!
        store.workspaces[index].tabs = tabs
    }

    @Test func aGroupMissingForAMomentKeepsItsPage() async {
        let (store, source, clock, full) = make()
        store.macConnection["mac-studio"] = .connecting
        setTabs(store, full.filter { $0.group == nil })
        let gone = Task { await source.groupStaysGone("g1") }
        await settle()
        clock.advance(by: .seconds(11))
        #expect(await gone.value == false, "a link coming back does not close the page")
        // The link is up and the group is back before the grace ends.
        store.macConnection["mac-studio"] = .connected
        let again = Task { await source.groupStaysGone("g1") }
        await settle()
        setTabs(store, full)
        clock.advance(by: .seconds(11))
        #expect(await again.value == false)
        clock.stop()
    }

    @Test func aGroupThatStaysEmptyOnAConnectedMacGoes() async {
        let (store, source, clock, full) = make()
        store.macConnection["mac-studio"] = .connected
        setTabs(store, full.filter { $0.group == nil })
        let gone = Task { await source.groupStaysGone("g1") }
        await settle()
        clock.advance(by: .seconds(11))
        #expect(await gone.value == true)
        clock.stop()
    }

    @Test func aGroupThePhoneEmptiedItselfGoesAtOnce() async {
        let (store, source, clock, full) = make()
        store.macConnection["mac-studio"] = .connected
        source.groupsEmptiedHere.insert("g1")
        setTabs(store, full.filter { $0.group == nil })
        #expect(await source.groupStaysGone("g1") == true)
        clock.stop()
    }
}
#endif
