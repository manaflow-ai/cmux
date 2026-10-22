import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-21: "OH YEAH LAWRENCE WANTED DEFAULT NEW WORKSPACE AT THE TOP". With no setting
/// (`workspaces.newPlacement` falls back to `top`), Cmd-N from a workspace in a group places the new one
/// right below it in that group (#22926), and from a loose one first in the list. The daemon's create
/// puts it first in the list either way, so the in-group case takes the app's move: every frame the list
/// applies must draw the new row only at its final slot (never at the top first, then in the group).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNTopInGroupFramesTests {
    /// Each frame as `section rows`: a group header as `g:<name>`, a member as `<group>/<id>`, a loose row as its id.
    static func rows(_ layout: SidebarLayout, model: SidebarModel, home: String?) -> [String] {
        layout.rows.compactMap { row in
            switch row.key {
            case let .group(group): "g:" + (model.group(group)?.name ?? group.rawValue)
            case let .workspace(id) where id.rawValue != home:
                row.group.map { (model.group($0)?.name ?? $0.rawValue) + "/" + id.rawValue } ?? id.rawValue
            default: nil
            }
        }
    }

    static func groups(_ model: SidebarModel) -> [SidebarGroup] {
        model.sections.flatMap(\.nodes).compactMap { node in
            if case let .group(group) = node { group } else { nil }
        }
    }

    @Test func cmdNFromAGroupMemberDrawsTheNewRowOnlyBelowItInTheGroupUnderTheDefault() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        // No settings file: the app's fallback decides (`top`).
        #expect(CmuxConfigSnapshot.newWorkspacePlacementFallback == .top)
        #expect(services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback == .top)
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
        let list = controller.sidebar.container.sidebarView.list
        let model = controller.sidebar.model
        let store = services.daemon.store
        let personal = services.machines.local.store.personal
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { personal.isLoaded }
        func settled(_ count: Int) -> Bool {
            PendingWorkspaceRows.shared.rows(in: window).isEmpty && store.workspaces.count >= count
                && !store.workspaces.contains(where: \.isProvisional)
        }
        // Four loose workspaces; the middle two become group "probe".
        let start = store.workspaces.count
        for press in 1...4 {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(String(format: "seed-%02d", press))]))
            await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { settled(start + press) }
        }
        let seeds = (1...4).compactMap { n in store.workspaces.first { $0.name == String(format: "seed-%02d", n) }?.id }
        try #require(seeds.count == 4, "seeds: \(store.workspaces.map(\.name))")
        let grouped = [seeds[1], seeds[2]].map(SidebarWorkspaceID.init)
        controller.sidebar.groupFlow.newGroup(of: grouped, name: "probe", byUser: false)
        func groupMembers() -> [String]? {
            Self.groups(model).first { $0.name == "probe" }.map { $0.workspaces.map(\.id.rawValue) }
        }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { groupMembers()?.count == 2 }
        let members = try #require(groupMembers(), "the group is never listed: \(model.sections)")
        try #require(members.count == 2, "group members \(members)")
        let anchor = members[0]
        services.windows.select(anchor, in: state)
        controller.showWorkspace(requested: state.workspaceID)
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { state.workspaceID == anchor }
        try #require(state.workspaceID == anchor)
        let home = NewWorkspacePlacements.home(services.machines)
        let before = Self.rows(list.displayed, model: model, home: home)
        let known = Set(store.workspaces.map(\.id))

        var frames: [[String]] = []
        list.onApply = { frames.append(Self.rows($0, model: model, home: home)) }
        _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
        func created() -> String? { store.workspaces.first { !known.contains($0.id) }?.id }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) {
            settled(start + 5) && created().map { id in groupMembers()?.contains(id) ?? false } ?? false
        }
        // Let any late reorder land too.
        try? await Task.sleep(for: .seconds(2))
        list.onApply = nil
        let after = Self.rows(list.displayed, model: model, home: home)
        let finalMembers = groupMembers()
        let made = created()
        await launched.stop()

        let id = try #require(made, "no workspace was made")
        print("cmdn-top-in-group: before \(before)")
        print("cmdn-top-in-group: after \(after)")
        for (index, frame) in frames.enumerated() { print("cmdn-top-in-group: frame \(index) \(frame)") }
        #expect(finalMembers == [anchor, id, members[1]], "group members \(String(describing: finalMembers))")
        let slot = "probe/" + anchor
        let expected = "probe/" + id
        let misplaced = frames.filter { frame in
            frame.contains { $0.hasSuffix(id) } && frame.firstIndex(of: slot).map { frame.indices.contains($0 + 1) && frame[$0 + 1] == expected } != true
        }
        #expect(misplaced.isEmpty, "frames that drew the new row away from its slot below \(anchor) in the group: \(misplaced)")
    }

    @Test func cmdNFromALooseWorkspaceDrawsTheNewRowOnlyFirstUnderTheDefault() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
        let list = controller.sidebar.container.sidebarView.list
        let model = controller.sidebar.model
        let store = services.daemon.store
        func settled(_ count: Int) -> Bool {
            PendingWorkspaceRows.shared.rows(in: window).isEmpty && store.workspaces.count >= count
                && !store.workspaces.contains(where: \.isProvisional)
        }
        let start = store.workspaces.count
        for press in 1...3 {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(String(format: "seed-%02d", press))]))
            await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { settled(start + press) }
        }
        // The last row (the oldest seed) is current: the new row still goes first.
        let home = NewWorkspacePlacements.home(services.machines)
        let before = Self.rows(list.displayed, model: model, home: home)
        let current = try #require(before.last)
        services.windows.select(current, in: state)
        controller.showWorkspace(requested: state.workspaceID)
        let known = Set(store.workspaces.map(\.id))
        var frames: [[String]] = []
        list.onApply = { frames.append(Self.rows($0, model: model, home: home)) }
        _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
        func created() -> String? { store.workspaces.first { !known.contains($0.id) }?.id }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(start + 4) && created() != nil }
        try? await Task.sleep(for: .seconds(2))
        list.onApply = nil
        let after = Self.rows(list.displayed, model: model, home: home)
        let made = created()
        await launched.stop()

        let id = try #require(made, "no workspace was made")
        print("cmdn-top-loose: before \(before)")
        for (index, frame) in frames.enumerated() { print("cmdn-top-loose: frame \(index) \(frame)") }
        #expect(after == [id] + before, "rows \(before) became \(after)")
        let misplaced = frames.filter { $0.contains(id) && $0.first != id }
        #expect(misplaced.isEmpty, "frames that drew the new row away from the top: \(misplaced)")
    }

    /// New Workspace in Section on the workspace list, with a loose workspace current: under the default the new row is first
    /// in every frame (it went to the bottom whatever `workspaces.newPlacement` said).
    @Test func newWorkspaceInSectionDrawsTheNewRowOnlyFirstUnderTheDefault() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
        let list = controller.sidebar.container.sidebarView.list
        let model = controller.sidebar.model
        let store = services.daemon.store
        func settled(_ count: Int) -> Bool {
            PendingWorkspaceRows.shared.rows(in: window).isEmpty && store.workspaces.count >= count
                && !store.workspaces.contains(where: \.isProvisional)
        }
        let start = store.workspaces.count
        for press in 1...3 {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(String(format: "seed-%02d", press))]))
            await RapidWorkspaceCreateTests.wait(within: .seconds(20)) { settled(start + press) }
        }
        let home = NewWorkspacePlacements.home(services.machines)
        let before = Self.rows(list.displayed, model: model, home: home)
        let current = try #require(before.first)
        services.windows.select(current, in: state)
        controller.showWorkspace(requested: state.workspaceID)
        let section = try #require(services.sidebarLayout.document.sections.first { if case .workspaces = $0.content { true } else { false } },
                                   "no workspace list section: \(services.sidebarLayout.document.sections.map(\.title))")
        let known = Set(store.workspaces.map(\.id))
        var frames: [[String]] = []
        list.onApply = { frames.append(Self.rows($0, model: model, home: home)) }
        let ran = services.registry.perform("sidebar.section.newWorkspace", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .sidebarSection, id: section.id.rawValue), origin: .user))
        func created() -> String? { store.workspaces.first { !known.contains($0.id) }?.id }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(start + 4) && created() != nil }
        try? await Task.sleep(for: .seconds(2))
        list.onApply = nil
        let after = Self.rows(list.displayed, model: model, home: home)
        let made = created()
        await launched.stop()

        #expect(ran)
        let id = try #require(made, "no workspace was made")
        for (index, frame) in frames.enumerated() { print("section-new-top: frame \(index) \(frame)") }
        #expect(after == [id] + before, "rows \(before) became \(after)")
        let misplaced = frames.filter { $0.contains(id) && $0.first != id }
        #expect(misplaced.isEmpty, "frames that drew the new row away from the top: \(misplaced)")
    }
}
