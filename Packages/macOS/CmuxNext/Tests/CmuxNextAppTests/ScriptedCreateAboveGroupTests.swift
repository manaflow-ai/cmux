import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import QuartzCore
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

    /// One sample of what the render server draws: the new row's and the group header's presentation tops (list view
    /// coordinates, y down), their opacities, and the animations their layers (and masks) carry.
    struct Drawn: CustomStringConvertible {
        var time: Double
        var row: CGFloat?
        var rowAlpha: Float = 0
        var header: CGFloat?
        var headerAlpha: Float = 0
        var animations: String
        var bothDrawn: Bool { row != nil && header != nil && rowAlpha > 0.05 && headerAlpha > 0.05 }
        var description: String {
            func f(_ v: CGFloat?) -> String { v.map { String(format: "%.1f", Double($0)) } ?? "-" }
            return String(format: "%.3f", time) + " row \(f(row))@\(String(format: "%.2f", rowAlpha)) h \(f(header))@\(String(format: "%.2f", headerAlpha))"
                + (animations.isEmpty ? "" : " [\(animations)]")
        }
    }

    /// `cmux workspace new` runs the app's New Workspace (`newTab`, origin `.cli`): its row shows at the press (the
    /// create's stand-in), then the daemon's workspace takes it over and the document places it. With `top` and the
    /// current workspace loose below the group, the row opens above the group. Sampled every 4 ms (more often than any
    /// display draws) from the press to 1.5 s after it, the row is drawn above the group's header in every sample where
    /// both draw: the recording showed the group drawn back above the row for one frame, with no view frame changed.
    @Test func aCLICreateIsDrawnAboveTheTopGroupInEveryFrame() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch(sessionEvents: true)
        let services = launched.services
        let url = launched.root.appendingPathComponent("cmux.json")
        try Data(#"{"workspaces":{"newPlacement":"top"}}"#.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        let window = try #require(services.windows.active?.state.id)
        let controller = try #require(services.windows.controller(for: window))
        let state = controller.state
        let list = controller.sidebar.container.sidebarView.list
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { services.sidebarDoc.store?.shown != nil }
        try #require(services.sidebarDoc.store?.shown != nil, "the same-tree daemon serves the sidebar document")
        func rows(_ layout: SidebarLayout) -> [String] {
            layout.rows.compactMap { if case let .workspace(id) = $0.key { id.rawValue } else { nil } }
        }
        func shows(_ id: String) -> Bool { rows(list.displayed).contains(id) }
        func settled(_ count: Int) -> Bool {
            services.windows.registry.members(of: window).count >= count && PendingWorkspaceRows.shared.rows(in: window).isEmpty
                && rows(list.displayed).count >= count
        }
        // Two workspaces made the way the CLI makes them, then grouped: the group is the first row.
        let start = services.windows.registry.members(of: window).count
        for count in (start + 1)...(start + 2) {
            _ = services.registry.perform("newTab", invocation: ActionInvocation(origin: .cli))
            await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(count) }
        }
        let seeded = rows(list.displayed)
        let home = NewWorkspacePlacements.home(services.machines)
        let made = Array(seeded.filter { $0 != home }.prefix(2))
        try #require(made.count == 2, "rows before grouping: \(seeded)")
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
        // The window shows a loose workspace below the group, so `top` opens the new row above the group.
        let loose = try #require(rows(list.displayed).first { group(of: $0) == nil }, "a loose row: \(rows(list.displayed))")
        services.windows.select(loose, in: state)
        controller.showWorkspace(requested: state.workspaceID)
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { state.workspaceID == loose }
        try? await Task.sleep(for: .milliseconds(500)) // the selection's own moves land first; test-only wait
        let before = Set(rows(list.displayed))
        let headerView = try #require(list.rowViews[.group(top)], "the group's header has a view")
        let headerLayer = try #require(headerView.layer)
        let container = try #require(list.layer)
        // Whether the list's layer space runs up (AppKit flips a flipped view's sublayers' geometry for it).
        let flipped = abs(headerLayer.frame.minY - headerView.frame.minY) > 0.5
        func drawnTop(_ view: NSView) -> (CGFloat, Float)? {
            guard view.superview === list, !view.isHidden, let layer = view.layer else { return nil }
            let shown = layer.presentation() ?? layer
            return (flipped ? container.bounds.height - shown.frame.maxY : shown.frame.minY, shown.opacity)
        }
        func keys(_ name: String, _ view: NSView?) -> String {
            guard let layer = view?.layer else { return "" }
            let own = layer.animationKeys() ?? [], mask = layer.mask?.animationKeys() ?? []
            return own.isEmpty && mask.isEmpty ? "" : "\(name):\(own.joined(separator: ","))\(mask.isEmpty ? "" : " mask:" + mask.joined(separator: ","))"
        }
        var samples: [Drawn] = []
        let started = CACurrentMediaTime()
        func sample() {
            let fresh = list.rowViews.first { key, _ in if case let .workspace(id) = key { !before.contains(id.rawValue) } else { false } }?.value
            let header = list.rowViews[.group(top)]
            let r = fresh.flatMap(drawnTop), h = header.flatMap(drawnTop)
            samples.append(Drawn(time: CACurrentMediaTime() - started, row: r?.0, rowAlpha: r?.1 ?? 0, header: h?.0, headerAlpha: h?.1 ?? 0,
                                 animations: [keys("row", fresh), keys("header", header), keys("line", list.groupLineViews.view(for: top))]
                                    .filter { !$0.isEmpty }.joined(separator: "; ")))
        }
        _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string("cli")], origin: .cli))
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < deadline {
            sample()
            try? await Task.sleep(for: .milliseconds(2)) // yields the main actor: the create, its passes and the frames run
        }
        await RapidWorkspaceCreateTests.wait(within: .seconds(30)) { settled(before.count + 1) }
        let after = rows(list.displayed)
        let groupAt = after.firstIndex { group(of: $0) == top }
        await launched.stop()

        let created = try #require(after.first { !before.contains($0) }, "the new row: \(after)")
        #expect((after.firstIndex(of: created) ?? .max) < (groupAt ?? 0), "the new row is not above the group: \(after)")
        // Only where the drawing changed, so the trace stays short.
        var trace: [Drawn] = []
        for s in samples {
            if let last = trace.last, last.row == s.row, last.header == s.header, last.animations == s.animations,
               abs(last.rowAlpha - s.rowAlpha) <= 0.01, abs(last.headerAlpha - s.headerAlpha) <= 0.01 { continue }
            trace.append(s)
        }
        print("cli-create-drawn: \(samples.count) samples, \(trace.count) changes:\n" + trace.map(\.description).joined(separator: "\n"))
        let under = samples.filter { $0.bothDrawn && ($0.row ?? 0) >= ($0.header ?? 0) - 0.5 }
        #expect(under.isEmpty, "samples that drew the new row at or below the group header: \(under.count) of \(samples.count): \(under.prefix(12).map(\.description))")
    }
}
