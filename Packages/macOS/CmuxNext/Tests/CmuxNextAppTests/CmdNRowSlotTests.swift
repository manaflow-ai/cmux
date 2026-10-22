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

/// Austin 2026-10-20: Cmd-N "draws the new workspace somewhere in the sidebar and then moves it via an
/// animation / glitch to the right place". On the sidebar document (`sidebar-doc-v1`) the daemon's
/// workspace replaced Cmd-N's pending row in the turn it took over the stand-in, while the document's
/// projection (rebuilt a hop later) did not place it yet: the row drew after every placed row, then
/// sprang to its slot. Every layout the list applies must show the new row only at its slot.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNRowSlotTests {
    @Test func cmdNDrawsTheNewRowOnlyAtItsSlot() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        // The slot named explicitly, so the base's default (`top`) does not decide the result: only the jump does.
        let url = launched.root.appendingPathComponent("cmux.json")
        try Data(#"{"workspaces":{"newPlacement":"afterCurrent"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        try #require(services.settings?.snapshot.newWorkspacePlacement == .afterCurrent)
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
        let list = controller.sidebar.container.sidebarView.list
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { SidebarDocStore.current?.shown != nil }
        try #require(SidebarDocStore.current?.shown != nil, "the same-tree daemon serves the sidebar document")
        func rows(_ layout: SidebarLayout) -> [String] {
            layout.rows.compactMap { if case let .workspace(id) = $0.key { id.rawValue } else { nil } }
        }
        func settled(_ count: Int) -> Bool {
            services.windows.registry.members(of: window).count >= count && PendingWorkspaceRows.shared.rows(in: window).isEmpty
                && rows(list.displayed).count >= count
        }
        func describe() -> String {
            "members \(services.windows.registry.members(of: window).count), pending \(PendingWorkspaceRows.shared.rows(in: window).count), drawn \(rows(list.displayed))"
        }
        // Three more workspaces, so the row below the anchor is not the end of the list.
        let start = services.windows.registry.members(of: window).count
        for count in (start + 1)...(start + 3) {
            _ = services.registry.perform("newTab")
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(count) }
            if !settled(count) { print("cmd-n-slot: not settled at \(count): \(describe())") }
        }
        let before = rows(list.displayed)
        // Two rows above the last: the daemon's own place (the end) is two rows below the slot.
        let at = before.count - 3
        guard at >= 0 else { await launched.stop(); Issue.record("rows before the press: \(before)"); return }
        let anchor = before[at]
        services.windows.select(anchor, in: state)
        controller.showWorkspace(requested: state.workspaceID)

        var frames: [[String]] = []
        list.onApply = { frames.append(rows($0)) }
        _ = services.registry.perform("newTab")
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(start + 4) && rows(list.displayed).count > before.count }
        if !settled(start + 4) { print("cmd-n-slot: not settled after the press: \(describe())") }
        list.onApply = nil
        let after = rows(list.displayed)
        await launched.stop()

        let created = try #require(after.first { !before.contains($0) }, "the new row: \(after)")
        #expect(after == Array(before[...at]) + [created] + before[(at + 1)...], "rows \(before) became \(after)")
        let elsewhere = frames.filter { frame in frame.contains(created) && frame.firstIndex(of: created) != frame.firstIndex(of: anchor).map { $0 + 1 } }
        #expect(elsewhere.isEmpty, "frames that drew the new row away from its slot below \(anchor): \(elsewhere)")
    }
}

/// Austin 2026-10-21: with the default `top` and the current workspace in a group, Cmd-N "makes it at
/// the top first and then moves it down and kind of flashes my sidebar". The daemon's create puts a
/// new workspace first below Home; the app then moved it into the group, right below the current one:
/// two orders, two animations. Every layout the list applies must show the new row only below the
/// current workspace, inside its group.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNInGroupRowSlotTests {
    @Test func cmdNInAGroupDrawsTheNewRowOnlyBelowTheCurrentOne() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let url = launched.root.appendingPathComponent("cmux.json")
        try Data(#"{"workspaces":{"newPlacement":"top"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        try #require(services.settings?.snapshot.newWorkspacePlacement == .top)
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
        let list = controller.sidebar.container.sidebarView.list
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { SidebarDocStore.current?.shown != nil }
        try #require(SidebarDocStore.current?.shown != nil, "the same-tree daemon serves the sidebar document")
        func rows(_ layout: SidebarLayout) -> [String] {
            layout.rows.compactMap { if case let .workspace(id) = $0.key { id.rawValue } else { nil } }
        }
        func settled(_ count: Int) -> Bool {
            services.windows.registry.members(of: window).count >= count && PendingWorkspaceRows.shared.rows(in: window).isEmpty
                && rows(list.displayed).count >= count
        }
        let start = services.windows.registry.members(of: window).count
        for count in (start + 1)...(start + 3) {
            _ = services.registry.perform("newTab")
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(count) }
        }
        // The two newest workspaces (first under `top`) go into a group; the window shows its first member.
        let seeded = rows(list.displayed)
        let home = NewWorkspacePlacements.home(services.machines)
        let loose = seeded.filter { $0 != home }
        try #require(loose.count >= 3, "rows before grouping: \(seeded)")
        let members = Array(loose.prefix(2))
        #expect(services.registry.perform("workspace.moveToNewGroup",
                                          invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: members[0]),
                                                                       arguments: ["name": .string("grp")], origin: .user)))
        func grouped(_ ids: [String]) -> Bool {
            controller.sidebar.model.sections.contains { section in
                section.nodes.contains { node in
                    guard case let .group(group) = node else { return false }
                    return ids.allSatisfy { id in group.workspaces.contains { $0.id.rawValue == id } }
                }
            }
        }
        // Into the same group: a drop on the first member's slot.
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { grouped([members[0]]) }
        try #require(grouped([members[0]]), "the group was made: \(controller.sidebar.model.sections)")
        let sections = SidebarRowSection.withoutPlaceholders(controller.sidebar.model.sections)
        let section = try #require(sections.first { $0.workspaces.contains { $0.id.rawValue == members[0] } }?.id)
        let into = try #require(WorkspaceSlot.below(members[0]).position(moving: [members[1]], section: section, in: sections))
        controller.sidebar.place([SidebarWorkspaceID(members[1])], at: into, in: sections)
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { grouped(members) }
        try #require(grouped(members), "both members in the group: \(controller.sidebar.model.sections)")
        let anchor = members[0]
        services.windows.select(anchor, in: state)
        controller.showWorkspace(requested: state.workspaceID)
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { state.workspaceID == anchor }
        let before = rows(list.displayed)
        let at = try #require(before.firstIndex(of: anchor))

        var frames: [[String]] = []
        var tags: [String] = []
        list.onApply = { layout in
            let frame = rows(layout)
            frames.append(frame)
            let fresh = frame.filter { !before.contains($0) }
            tags.append(fresh.map { id in
                let pending = PendingWorkspaceRows.shared.rows(in: window).contains { $0.id == id } ? "+pend" : ""
                let provisional = services.machines.workspace(id: id)?.0.isProvisional == true ? "+prov" : ""
                let item = SidebarDocWiring.item(workspace: id, services.machines) != nil ? "+d" : ""
                let placing = services.windows.pendingPlacements[id] != nil ? "+placing" : ""
                return "@\(frame.firstIndex(of: id) ?? -1)\(pending)\(provisional)\(item)\(placing)"
            }.joined(separator: ","))
        }
        let intentBefore = SidebarDocStore.current?.lastIntentKey
        _ = services.registry.perform("newTab")
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(before.count + 1) && rows(list.displayed).count > before.count }
        // A late reorder (the item's arrival, a placement echo) would draw within this; test-only wait.
        try? await Task.sleep(for: .seconds(1))
        list.onApply = nil
        let after = rows(list.displayed)
        let intentAfter = SidebarDocStore.current?.lastIntentKey
        await launched.stop()

        let created = try #require(after.first { !before.contains($0) }, "the new row: \(after)")
        print("cmd-n-group: anchor @\(at), frames \(frames.count): \(tags.joined(separator: " | "))")
        #expect(after == Array(before[...at]) + [created] + before[(at + 1)...], "rows \(before) became \(after)")
        let elsewhere = frames.filter { frame in frame.contains(created) && frame.firstIndex(of: created) != frame.firstIndex(of: anchor).map { $0 + 1 } }
        #expect(elsewhere.isEmpty, "frames that drew the new row away from its slot below \(anchor): \(elsewhere.count) of \(frames.count): \(tags)")
        #expect(intentAfter == intentBefore, "the app sent its own sidebar move for the new workspace (a second state change)")
    }
}
