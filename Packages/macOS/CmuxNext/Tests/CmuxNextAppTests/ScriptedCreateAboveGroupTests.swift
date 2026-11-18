import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-08: "there's the sidebar where when things maybe open or shift a bit, there's like still a bit of a
/// flicker on that, like individual top group". A recording of the nightly (every display frame) showed it for a
/// workspace a script makes (`cmux workspace new`, the daemon's `workspace.create` with a terminal) while a group is the
/// first row: the new row drew above the group, then for one frame under it (the group jumped back up a row), then
/// above it again. Every layout the list applies must show the new row only at its slot, above the group.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ScriptedCreateAboveGroupTests {
    @Test func aScriptedCreateDrawsItsRowOnlyAboveTheTopGroup() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch(sessionEvents: true)
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let list = controller.sidebar.container.sidebarView.list
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { services.sidebarDoc.store?.shown != nil }
        let doc = try #require(services.sidebarDoc.store, "the same-tree daemon serves the sidebar document")
        try #require(doc.shown != nil, "the same-tree daemon serves the sidebar document")
        let connection = try #require(services.daemon.connection)
        func rows(_ layout: SidebarLayout) -> [String] {
            layout.rows.compactMap { if case let .workspace(id) = $0.key { id.rawValue } else { nil } }
        }
        func shows(_ id: String) -> Bool { rows(list.displayed).contains(id) }
        // The create answers with the workspace's resource id; the rows name it by the store's id.
        func listed(_ resource: ResourceID) -> String? { services.daemon.store.workspaces.first { $0.resourceID == resource }?.id }
        func make(_ name: String) async throws -> String {
            let resource = try await connection.state.createWorkspace(name: name, ephemeral: false, terminal: true, focus: false).workspaceID
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { listed(resource) != nil }
            return try #require(listed(resource), "the store lists \(name)")
        }
        // Two workspaces made the way the script makes them: each goes first (`top`).
        var made: [String] = []
        for index in 0..<2 {
            let id = try await make("grp-\(index)")
            made.append(id)
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { shows(id) }
        }
        try #require(made.allSatisfy(shows), "the seeded rows: \(rows(list.displayed))")
        // Both into one group: it is the first group, above every loose row but Home.
        controller.sidebar.groupFlow.newGroup(of: made.map(SidebarWorkspaceID.init), name: "Top", byUser: false)
        func group(of id: String) -> GroupID? {
            controller.sidebar.model.sections.lazy.flatMap(\.nodes).compactMap { node -> GroupID? in
                guard case let .group(group) = node, group.workspaces.contains(where: { $0.id.rawValue == id }) else { return nil }
                return group.id
            }.first
        }
        let grouped = await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
            guard let first = group(of: made[0]) else { return false }
            return made.allSatisfy { group(of: $0) == first } && list.displayed.row(for: .group(first)) != nil
        }
        try #require(grouped, "both members in one group: \(rows(list.displayed))")
        let top = try #require(group(of: made[0]))
        let before = rows(list.displayed)
        // The group's first drawn member: a row above the group draws before it, a row under the group after its last.
        let members = before.filter { group(of: $0) == top }
        let firstMember = try #require(members.first)
        let home = NewWorkspacePlacements.home(services.machines)
        try #require(before.filter { $0 != home }.first == firstMember, "the group is the first row: \(before)")

        var frames: [[String]] = []
        var tags: [String] = []
        list.onApply = { layout in
            let frame = rows(layout)
            frames.append(frame)
            let fresh = frame.filter { !before.contains($0) }
            tags.append(fresh.map { id in
                let item = services.sidebarDoc.item(workspace: id) != nil ? "+d" : ""
                let lag = doc.version != doc.shownVersion ? "+lag" : ""
                let header = layout.row(for: .group(top)).map { "h\($0.y)" } ?? "h-"
                return "@\(frame.firstIndex(of: id) ?? -1)\(item)\(lag) \(header)"
            }.joined(separator: ","))
        }
        let created = try await make("cli")
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { shows(created) && services.sidebarDoc.item(workspace: created) != nil }
        // A late reorder (the item's arrival, a placement echo) would draw within this; test-only wait.
        try? await Task.sleep(for: .seconds(1))
        list.onApply = nil
        let after = rows(list.displayed)
        await launched.stop()

        print("scripted-create-above-group: before \(before), frames \(frames.count): \(tags.joined(separator: " | "))")
        let at = try #require(after.firstIndex(of: created), "the new row: \(after)")
        #expect(at < (after.firstIndex(of: firstMember) ?? 0), "the new row is not above the group: \(after)")
        let under = frames.filter { frame in
            guard let row = frame.firstIndex(of: created), let member = frame.firstIndex(of: firstMember) else { return false }
            return row > member
        }
        #expect(under.isEmpty, "frames that drew the new row under the top group: \(under.count) of \(frames.count): \(tags)")
    }
}
