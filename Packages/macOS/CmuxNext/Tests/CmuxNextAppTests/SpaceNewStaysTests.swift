import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// New Space, on the real daemon: the window switches to the new space and stays there, its first workspace is born in
/// it (never listed in the space the person left), and switching back returns to the workspace they were on.
/// Leo 2026-11-11: "When you create a new one, it should just be at that one. It shouldn't just bounce you back to your
/// previously created one ... it also has a stupid animation on the sidebar due to that creating a new workspace within
/// the existing thing". Before, the first workspace showed unpinned (so in `default`) until its pin mirrored: its row
/// was inserted in the old space's list and the window fell back there.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SpaceNewStaysTests {
    @Test func aNewSpaceIsShownAtOnceAndKeptAndTheOldSpaceNeverChanges() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let state = try #require(services.windows.states[window])
        let controller = try #require(services.windows.controller(for: window))
        let list = controller.sidebar.container.sidebarView.list
        func rows(_ layout: SidebarLayout) -> [String] {
            layout.rows.compactMap { if case let .workspace(id) = $0.key { id.rawValue } else { nil } }
        }
        func visible(in profile: ProfileID) -> [String] {
            WindowProfiles.visible(services.windows.registry.members(of: window), profile: profile, machines: services.machines)
        }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { services.machines.local.store.personal.isLoaded && state.workspaceID != nil && !rows(list.displayed).isEmpty }
        try #require(services.machines.local.store.personal.isLoaded, "the daemon has no spaces")
        let old = state.profileID, before = state.workspaceID, oldRows = rows(list.displayed), oldList = visible(in: old)
        let spaces = services.machines.local.store.profileIDs

        var frames: [[String]] = [], profiles: [ProfileID] = []
        list.onApply = { frames.append(rows($0)); profiles.append(state.profileID) }
        _ = services.registry.perform("space.new", invocation: ActionInvocation(origin: .user))
        func created() -> ProfileID? { services.machines.local.store.profileIDs.first { !spaces.contains($0) } }
        let settled = await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
            guard let space = created(), state.profileID == space, let shown = state.workspaceID else { return false }
            return services.machines.workspace(id: shown).map { !$0.0.isProvisional } == true && PendingWorkspaceRows.shared.rows(in: window).isEmpty
        }
        // Well past the pin's mirror and the create's snapshot: no late fallback takes the window back.
        _ = await RapidWorkspaceCreateTests.wait(within: .seconds(2)) { state.profileID != created() }
        let space = created(), first = state.workspaceID, profileAfter = state.profileID
        let oldListAfter = visible(in: old)
        list.onApply = nil
        services.windows.switchProfile(old, in: state)
        let back = state.workspaceID, backProfile = state.profileID
        await launched.stop()

        let new = try #require(space, "space.new made no space")
        #expect(settled, "the window never settled in the new space with its first workspace")
        #expect(profileAfter == new, "the window bounced to \(profileAfter) after its new space \(new)")
        #expect(oldListAfter == oldList, "the old space's list changed: \(oldList) became \(oldListAfter)")
        let newRow = try #require(first)
        // The old space's list never drew the new row (no insert there, no remove when it migrated) and, once the window
        // showed the new space, it never drew the old space's rows again (no bounce).
        let inserted = frames.filter { $0.contains(newRow) && $0.contains(where: oldRows.contains) }
        #expect(inserted.isEmpty, "frames that drew the new workspace among the old space's rows: \(inserted)")
        let shownAt = profiles.firstIndex(of: new) ?? profiles.count
        let bounced = zip(profiles, frames).dropFirst(shownAt).filter { $0.0 != new || $0.1.contains(where: oldRows.contains) }
        #expect(bounced.isEmpty, "frames after the switch that showed another space: \(bounced.map(\.1))")
        #expect(backProfile == old && back == before, "switching back showed \(back ?? "nothing") in \(backProfile), not \(before ?? "nothing") in \(old)")
    }
}

/// The pin a new workspace expects (`PersonalStore.expectPin`) is a pin from the press until the daemon lists its own.
@MainActor @Suite struct ExpectedPinTests {
    @Test func anExpectedPinCountsUntilTheDaemonListsOneThenTheDaemonsWins() {
        let personal = PersonalStore(), work = ProfileID(rawValue: "work"), other = ProfileID(rawValue: "other")
        personal.expectPin(session: "s", key: "k", room: work)
        #expect(personal.pinnedRooms["s"]?["k"] == work)
        #expect(RoomMembership(pins: personal.pinnedRooms).contains(.init(session: "s", key: "k"), in: work))
        // The daemon pinned it elsewhere (a move raced the create): its pin wins and the expectation is done.
        personal.pins = [WorkspacePin(sessionID: "s", workspaceKey: WorkspaceKey(rawValue: "k"), profile: other)]
        #expect(personal.pinnedRooms["s"]?["k"] == other)
        #expect(personal.expectedPins.isEmpty)
    }

    @Test func aFailedCreateDropsItsExpectedPin() {
        let personal = PersonalStore()
        personal.expectPin(session: "s", key: "k", room: ProfileID(rawValue: "work"))
        personal.pins = [WorkspacePin(sessionID: "s", workspaceKey: WorkspaceKey(rawValue: "j"), profile: .defaultProfile)]
        #expect(personal.pinnedRooms["s"]?["k"] != nil, "an unrelated snapshot kept it")
        personal.dropExpectedPin(key: "k")
        #expect(personal.pinnedRooms["s"]?["k"] == nil)
        #expect(personal.pinnedRooms["s"]?["j"] == .defaultProfile)
    }
}
