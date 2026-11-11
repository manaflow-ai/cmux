import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// A bulk or selection close of a group's last workspaces deletes the emptied unpinned group
/// (`PersonalGroupLife.groupsClosing`), and the close's Undo brings it back: the workspaces reopen
/// in the group, which keeps its id, name, pin and place among the groups
/// (`WorkspaceGroupClose.undoGroups`). Without the group in the Undo, the workspaces came back loose.
/// Runs on a same-tree cmux-tui daemon and the real window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(6)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct GroupCloseCleanupUndoTests {
    private static let toastID = "workspaces-closed"

    @Test func closeOtherWorkspacesThenUndoRestoresTheGroup() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let setup = try await Self.setUp(services)
            _ = services.registry.perform("palette.closeOtherWorkspaces", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .workspace, id: setup.keep), origin: .user).confirmed())
            try await Self.undoRestores(setup, services)
        }
    }

    @Test func closeTheSelectionThenUndoRestoresTheGroup() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let setup = try await Self.setUp(services)
            WorkspaceSelectionClose.close(setup.members, in: setup.controller.state, services)
            try await Self.undoRestores(setup, services)
        }
    }

    private struct Setup {
        let controller: WindowController
        let window: NSWindow
        let group: WorkspaceGroupID
        let members: [String]
        let keep: String
        /// The groups in order, and the group's name and pin, before the close.
        let order: [WorkspaceGroupID]
        let name: String
        let pinned: Bool
    }

    /// Two workspaces alone in "undo-group" and, in the same window, one in "other-group" that
    /// stays open, so the groups have an order and the window keeps a workspace for the toast.
    private static func setUp(_ services: AppServices) async throws -> Setup {
        try await PinnedPageTests.until({ !services.windows.registry.isLaunching && services.machines.local.store.personal.isLoaded },
                                        within: .seconds(60))
        let controller = try #require(services.windows.active)
        let window = try #require(controller.window)
        let context = AppActionContext(services: services), personal = services.machines.local.store.personal
        var ids: [String] = []
        for name in ["undo-keep", "undo-1", "undo-2"] {
            ids.append(try await services.windows.createWorkspace(WorkspaceSpawn(name: name), into: controller.state.id))
        }
        try await PinnedPageTests.until({ ids.allSatisfy { services.workspace(id: $0) != nil } }, within: .seconds(60))
        let keep = ids[0], members = Array(ids[1...])
        func group(_ id: String, named name: String) async throws -> WorkspaceGroupID {
            _ = services.registry.perform("newWorkspaceGroup", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .workspace, id: id), arguments: ["name": .string(name)], origin: .cli))
            try await PinnedPageTests.until({ personal.groups.contains { $0.name == name } }, within: .seconds(30),
                                            report: { "groups \(personal.groups.map(\.name))" })
            return try #require(personal.groups.first { $0.name == name }?.id)
        }
        let undoGroup = try await group(members[0], named: "undo-group")
        _ = try await group(keep, named: "other-group")
        _ = services.registry.perform("moveWorkspaceToGroup", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .workspace, id: members[1]),
            arguments: ["group": .target(ActionTargetRef(kind: .workspaceGroup, id: undoGroup.rawValue))], origin: .user))
        try await PinnedPageTests.until({ Set(context.workspaces(inPersonalGroup: undoGroup).map(\.id)) == Set(members) },
                                        within: .seconds(30),
                                        report: { "undo-group holds \(context.workspaces(inPersonalGroup: undoGroup).map(\.name))" })
        let model = try #require(personal.group(undoGroup))
        return Setup(controller: controller, window: window, group: undoGroup, members: members, keep: keep,
                     order: personal.groups.map(\.id), name: model.name, pinned: model.pinned)
    }

    /// The close deletes the emptied group; its Undo brings the group back in its place with both workspaces.
    private static func undoRestores(_ setup: Setup, _ services: AppServices) async throws {
        let context = AppActionContext(services: services), personal = services.machines.local.store.personal
        // DIAG (not for merge): each change of the groups, the open workspaces, the personal rows and the closed items, with its time.
        let timeline = DiagTimeline(), clock = ContinuousClock(), start = clock.now
        @MainActor func short(_ id: String?) -> String { id.map { String($0.suffix(4)) } ?? "-" }
        @MainActor func snap() -> String {
            let open: [String] = services.machines.daemons.flatMap(\.store.workspaces).map { workspace in
                workspace.name + "/" + short(workspace.key?.rawValue) + "[" + short(context.personalGroupID(of: workspace)?.rawValue) + "]"
            }
            let rows: [String] = personal.workspaces.map { short($0.workspaceKey.rawValue) + ":" + short($0.group?.rawValue) }
            let closed: [String] = DaemonClosedHistory.entries([.workspace], in: services).map { entry in
                let names: [String] = entry.item.memberNames.map { $0 ?? "nil" }
                return short(entry.item.id) + " m=\(names) g=" + short(entry.item.group?.id)
            }
            let groups: [String] = personal.groups.map { $0.name + "/" + short($0.id.rawValue) }
            let ending: [String] = personal.endingGroups.map { short($0.rawValue) }
            return "groups \(groups) ending \(ending) open \(open) rows \(rows) closed \(closed)"
        }
        var last = ""
        // Polls `condition` each 4 ms up to `limit` and writes each change of the snapshot.
        @MainActor func watch(_ limit: Duration, _ condition: () -> Bool) async {
            let deadline = clock.now + limit
            repeat {
                let now = snap()
                if now != last { timeline.add("+\(start.duration(to: clock.now)) \(now)"); last = now }
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(4))
            } while clock.now < deadline
        }
        defer { print("DIAG-TIMELINE group \(short(setup.group.rawValue)):\n" + timeline.lines.joined(separator: "\n")) }
        await watch(.seconds(60)) { personal.group(setup.group) == nil && setup.members.allSatisfy { services.workspace(id: $0) == nil } }
        try await PinnedPageTests.until({ personal.group(setup.group) == nil && setup.members.allSatisfy { services.workspace(id: $0) == nil } },
                                        within: .seconds(60),
                                        report: { "group \(personal.group(setup.group)?.name ?? "deleted"), open \(setup.members.filter { services.workspace(id: $0) != nil })" })
        await watch(.seconds(10)) { CmuxToastCenter.shared.toasts(in: setup.window).contains { $0.id == Self.toastID } }
        try await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: setup.window).contains { $0.id == Self.toastID } },
                                        within: .seconds(10), report: { "toasts \(CmuxToastCenter.shared.toasts(in: setup.window).map(\.message))" })
        timeline.add("+\(start.duration(to: clock.now)) UNDO PRESSED")
        #expect(CmuxToastCenter.shared.runAction(id: Self.toastID, in: setup.window))
        @MainActor func held() -> Set<String> { Set(context.workspaces(inPersonalGroup: setup.group).map(\.name)) }
        await watch(.seconds(60)) { held() == ["undo-1", "undo-2"] }
        timeline.add("+\(start.duration(to: clock.now)) FIRST WAIT ENDS: held \(held().sorted())")
        // What comes in the 2 seconds after (a late write shows here).
        await watch(.seconds(2)) { false }
        try await PinnedPageTests.until({ held() == ["undo-1", "undo-2"] }, within: .seconds(5), report: {
            let open = services.machines.daemons.flatMap(\.store.workspaces).map { "\($0.name)[\(context.personalGroupID(of: $0)?.rawValue ?? "-")]" }
            let rows = personal.workspaces.map { "\($0.workspaceKey.rawValue):\($0.group?.rawValue ?? "-")" }
            let closed = DaemonClosedHistory.entries([.workspace], in: services).map {
                "\($0.item.id) name=\($0.item.name ?? "nil") members=\($0.item.memberNames.map { $0 ?? "nil" }) group=\($0.item.group?.id ?? "-")"
            }
            return "group \(personal.group(setup.group)?.name ?? "missing") holds \(held().sorted()); groups \(personal.groups.map(\.name)); DIAG group id \(setup.group.rawValue); open \(open); rows \(rows); closed \(closed)"
        })
        let restored = try #require(personal.group(setup.group))
        #expect(restored.name == setup.name)
        #expect(restored.pinned == setup.pinned)
        #expect(personal.groups.map(\.id) == setup.order, "the group came back in another place: \(personal.groups.map(\.name))")
    }
}

/// DIAG (not for merge): the lines of one test's timeline.
@MainActor private final class DiagTimeline {
    var lines: [String] = []
    func add(_ line: String) { lines.append(line) }
}
