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

/// Leo 2026-10-22: "OH YEAH LAWRENCE WANTED DEFAULT NEW WORKSPACE AT THE TOP". With no setting
/// (`workspaces.newPlacement` falls back to `top`), Cmd-N from a loose workspace and New Workspace in Section
/// draw the new row first in every frame the list applies (never elsewhere, then moved). The in-group slot is
/// pinned by `NewWorkspaceInGroupTests`: in this harness a group made through the state store is never listed
/// in the window's sidebar (#22926), so a frame test cannot set one up.
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
