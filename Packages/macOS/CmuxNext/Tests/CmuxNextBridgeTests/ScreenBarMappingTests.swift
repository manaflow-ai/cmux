import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import Foundation
import Testing
@testable import CmuxNextBridge

/// The bottom screen tab bar: shown iff a workspace has more than one
/// screen; items carry each screen's name, color, icon, pin, and group.
@MainActor
struct ScreenBarMappingTests {
    private func tree(_ edit: (inout DaemonTree) -> Void = { _ in }) throws -> DaemonStore {
        let url = try #require(Bundle.module.url(forResource: "list-workspaces", withExtension: "json", subdirectory: "Fixtures"))
        var tree = try JSONDecoder().decode(BridgeFixture.Envelope.self, from: Data(contentsOf: url)).data
        edit(&tree)
        let store = DaemonStore()
        store.apply(snapshot: tree)
        return store
    }

    private func map(_ workspace: WorkspaceModel) -> ScreenBarMapping.Snapshot {
        ScreenBarMapping.snapshot(workspace, untitled: { "Screen \($0)" }, emojiIcon: { _ in .symbol("face.smiling") })
    }

    @Test func barIsVisibleOnlyWithTwoOrMoreScreens() throws {
        let store = try tree()
        let two = map(try #require(store.workspaces.first))
        #expect(two.isVisible)
        #expect(two.items.count == 2)

        let one = map(try #require(try tree { $0.workspaces[0].screens.removeLast() }.workspaces.first))
        #expect(!one.isVisible)
        let none = map(try #require(store.workspaces.last))
        #expect(!none.isVisible)
    }

    @Test func itemsCarryNameFallbackColorIconPinAndUnread() throws {
        let store = try tree {
            $0.workspaces[0].screens[1].name = "Logs"
            $0.workspaces[0].screens[1].color = "green"
            $0.workspaces[0].screens[1].icon = "server.rack"
            $0.workspaces[0].screens[1].pinned = true
            $0.workspaces[0].screens[0].icon = "🚀"
        }
        let snapshot = map(try #require(store.workspaces.first))
        let first = snapshot.items[0], second = snapshot.items[1]
        #expect(first.title == "Screen 1")
        #expect(first.icon == .symbol("face.smiling"))
        #expect(first.isUnread)
        #expect(first.tint == nil)
        #expect(second.title == "Logs")
        #expect(second.tint == .green)
        #expect(second.icon == .symbol("server.rack"))
        #expect(second.isPinned)
        #expect(!second.isUnread)
        #expect(snapshot.items.map(\.id.rawValue) == store.workspaces[0].screens.map(\.id))
    }

    @Test func groupsMapToChipsAndMembership() throws {
        let store = try tree {
            $0.workspaces[0].screenGroups = [ScreenGroupSnapshot(id: "sgrp_1", name: "Build", color: "orange", collapsed: true,
                                                                  savedID: "ssaved_1", start: 0, screens: [5])]
            $0.workspaces[0].screens[0].group = "sgrp_1"
        }
        let snapshot = map(try #require(store.workspaces.first))
        #expect(snapshot.groups == [TabGroupItem(id: "sgrp_1", name: "Build", colorToken: .orange, isCollapsed: true, isSaved: true)])
        #expect(snapshot.items[0].groupID == "sgrp_1")
        #expect(snapshot.items[1].groupID == nil)
    }

    @Test func iconKindSeparatesSymbolsFromEmoji() {
        #expect(ScreenBarMapping.isSymbolName("server.rack"))
        #expect(ScreenBarMapping.isSymbolName("1.circle"))
        #expect(!ScreenBarMapping.isSymbolName("🚀"))
        #expect(!ScreenBarMapping.isSymbolName("👩‍💻"))
        #expect(!ScreenBarMapping.isSymbolName(""))
    }
}
