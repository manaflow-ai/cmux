import AppKit
@testable import CmuxNextApp
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Testing

/// Move Space to This Window and Merge All Windows next to shared spaces (#44275: two windows on one space list each
/// other's workspaces as guests). A gather moves only a window's own workspaces, a window left with guests only
/// closes, and a window the space was taken from does not show it again as guests until the person moves it to a space.
/// Fixtures from `GatherWindowsTests`: k0, k1 in room0; k2, k3 in room1; `wh` a window's Home in no space.
@MainActor @Suite(.serialized, .closesItsWindows)
struct GatherWindowsSharedSpaceTests {
    typealias Fixture = GatherWindowsTests

    /// Without a gather, two windows on one space still list each other's workspaces as guests (#44275).
    @Test func twoWindowsOnOneSpaceStillShareIt() throws {
        let services = try Fixture.services()
        defer { Fixture.closeAll(services) }
        let here = try Fixture.open(["k0"], services), there = try Fixture.open(["k1"], services)
        #expect(here.state.profileID == Fixture.rooms[0] && there.state.profileID == Fixture.rooms[0])

        let registry = services.windows.registry.value
        #expect(registry.isGuest("k1", in: here.state.id), "a window on the space did not list the other window's workspace")
        #expect(registry.isGuest("k0", in: there.state.id), "a window on the space did not list the other window's workspace")
        #expect(registry.owner(of: "k0") == here.state.id && registry.owner(of: "k1") == there.state.id)
    }

    /// The window the space was taken from keeps only its own list through later transitions, and lists the space's
    /// workspaces as guests again once the person moves it to a space.
    @Test func aGatherSourceViewsAgainOnlyAfterItEntersASpace() throws {
        let services = try Fixture.services()
        defer { Fixture.closeAll(services) }
        let here = try Fixture.open(["k0"], services), there = try Fixture.open(["k2", "wh"], services)

        try services.windows.bringSpace(Fixture.rooms[1], into: here.state)
        #expect(services.windows.registry.value.window(there.state.id)?.workspaceIDs == ["wh"])
        services.windows.transition { _ in WindowRegistry.Changes() } // any later membership write sets the guests again
        #expect(services.windows.registry.value.window(there.state.id)?.workspaceIDs == ["wh"], "the moved space came back as guests")

        services.windows.switchProfile(Fixture.rooms[0], in: there.state)
        services.windows.switchProfile(Fixture.rooms[1], in: there.state)
        #expect(services.windows.registry.value.isGuest("k2", in: there.state.id), "the window did not share the space it entered")
    }

    /// A window that only views the space (Open Space in New Window) gives up nothing, so its pending workspace does not
    /// refuse the move, and it stays open listing the space's workspaces, now owned here.
    @Test func aViewOfTheSpaceIsNoSource() throws {
        let services = try Fixture.services()
        defer { Fixture.closeAll(services) }
        let here = try Fixture.open(["k0"], services), there = try Fixture.open(["k2", "k3"], services)
        let view = try #require(services.windows.openView(id: UUID().uuidString.lowercased(), of: Fixture.rooms[1]))
        #expect(services.windows.registry.value.window(view.state.id)?.ownedIDs.isEmpty == true)
        services.windows.pendingPlacements["k-new-view"] = PendingPlacement(window: view.state.id, slot: nil, byDefault: nil, then: nil)
        defer { services.windows.pendingPlacements["k-new-view"] = nil }

        try services.windows.bringSpace(Fixture.rooms[1], into: here.state)

        let registry = services.windows.registry.value
        #expect(registry.window(there.state.id) == nil, "the emptied window stayed")
        #expect(registry.owner(of: "k2") == here.state.id && registry.owner(of: "k3") == here.state.id)
        #expect(registry.window(view.state.id)?.isOpen == true, "the view closed")
        #expect(Set(registry.window(view.state.id)?.workspaceIDs ?? []) == ["k2", "k3"])
    }
}
