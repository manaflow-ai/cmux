import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-11: "When you create a new one, it should just be at that one. It shouldn't just bounce you back to
/// your previously created one." New Space enters the new space and creates its first workspace, pinned there before
/// the create. The pin's reply comes before `personal-changed`'s refetch, and the workspace's own delta can come
/// first: the workspace then reads as unpinned (so in `default`), the new space shows nothing, the claim has landed,
/// and the selection repair moved the window back to the space it came from, where the row showed until the pin
/// arrived and slid it away. The pin the app sent counts from the press (`PersonalStore.expectedPins`).
@MainActor @Suite(.serialized)
struct NewSpaceStaysTests {
    @Test func theNewSpaceKeepsItsWindowWhenItsWorkspaceComesBeforeItsPin() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.store.personal.expectPin(session: "s-local", key: WorkspaceKey(rawValue: "k2"), room: fixture.fresh)
        fixture.arriveBeforePin()
        #expect(fixture.state.profileID == fixture.fresh, "the window bounced back to \(fixture.state.profileID.rawValue)")
        #expect(fixture.state.workspaceID == "k2", "the new space does not show its first workspace")
        #expect(WindowProfiles.visible(["k1", "k2"], profile: .defaultProfile, machines: fixture.services.machines) == ["k1"],
                "the new workspace still lists in the space the window came from")

        // The refetch carries the pin: the expectation goes, and nothing moves.
        fixture.apply(pinned: true)
        #expect(fixture.store.personal.expectedPins.isEmpty)
        fixture.services.windows.reconcileMembership()
        #expect(fixture.state.profileID == fixture.fresh)
        #expect(fixture.state.workspaceID == "k2")
    }

    /// The race itself, without the expectation: this is the bounce Leo saw.
    @Test func withoutTheExpectationTheWindowFallsBack() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.arriveBeforePin()
        #expect(fixture.state.profileID == .defaultProfile)
    }

    @Test func aFailedCreateForgetsItsExpectedPin() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let personal = fixture.store.personal
        personal.expectPin(session: "s-local", key: WorkspaceKey(rawValue: "k2"), room: fixture.fresh)
        #expect(personal.pinnedRooms["s-local"]?["k2"] == fixture.fresh)
        _ = fixture.services.windows.createFailed("k2", DaemonError.notConnected)
        #expect(personal.expectedPins.isEmpty)
        #expect(personal.pinnedRooms["s-local"]?["k2"] == nil)
    }

    /// A create that reuses a key the daemon already pins brings no refetch: no expectation, or it would outlive an unpin.
    @Test func anAlreadyPinnedKeyGetsNoExpectation() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.apply(pinned: true)
        fixture.store.personal.expectPin(session: "s-local", key: WorkspaceKey(rawValue: "k2"), room: fixture.fresh)
        #expect(fixture.store.personal.expectedPins.isEmpty)
    }

    @MainActor
    final class Fixture {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let fresh = ProfileID(rawValue: "room-new")
        let controller: WindowController
        var store: DaemonStore { services.machines.local.store }
        var state: WindowState { controller.state }

        init() throws {
            _ = NSApplication.shared
            let store = services.machines.local.store
            let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1","personal-mixed-order-v1"]}"#
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: Self.tree(workspaces: ["k1"], pinned: false, fresh: fresh))
            services.windows.ordersWindowsIn = false
            controller = try #require(services.windows.openWindow(workspaces: ["k1"], frame: CGRect(x: 120, y: 120, width: 900, height: 600)))
            #expect(controller.state.profileID == .defaultProfile)
        }

        /// New Space's switch into the new space with its first workspace claimed, then the workspace's delta before
        /// the pin's refetch.
        func arriveBeforePin() {
            services.windows.claimNew(workspaceID: "k2", window: state.id)
            state.enterProfile(fresh)
            store.apply(snapshot: Self.tree(workspaces: ["k1", "k2"], pinned: false, fresh: fresh))
            services.windows.reconcileMembership()
            services.windows.repairSelections(previous: services.windows.membersByWindow)
        }

        func apply(pinned: Bool) {
            store.apply(snapshot: Self.tree(workspaces: ["k1", "k2"], pinned: pinned, fresh: fresh))
        }

        func close() {
            controller.teardown()
            controller.window?.close()
        }

        static func tree(workspaces keys: [String], pinned: Bool, fresh: ProfileID) -> DaemonTree {
            var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [])
            })
            tree.personal = PersonalState(
                sessions: [SessionRecord(id: "s-local")],
                profiles: [ProfileSnapshot(id: .defaultProfile, name: "Default", index: 0), ProfileSnapshot(id: fresh, name: "New", index: 1)],
                pins: pinned ? [WorkspacePin(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k2"), profile: fresh)] : [],
                workspaces: keys.enumerated().map { PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0) })
            return tree
        }
    }
}
