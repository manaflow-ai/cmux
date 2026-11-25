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
        try await PinnedPageTests.until({ personal.group(setup.group) == nil && setup.members.allSatisfy { services.workspace(id: $0) == nil } },
                                        within: .seconds(60),
                                        report: { "group \(personal.group(setup.group)?.name ?? "deleted"), open \(setup.members.filter { services.workspace(id: $0) != nil })" })
        try await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: setup.window).contains { $0.id == Self.toastID } },
                                        within: .seconds(10), report: { "toasts \(CmuxToastCenter.shared.toasts(in: setup.window).map(\.message))" })
        #expect(CmuxToastCenter.shared.runAction(id: Self.toastID, in: setup.window))
        @MainActor func held() -> Set<String> { Set(context.workspaces(inPersonalGroup: setup.group).map(\.name)) }
        try await PinnedPageTests.until({ held() == ["undo-1", "undo-2"] }, within: .seconds(60), report: {
            "group \(personal.group(setup.group)?.name ?? "missing") holds \(held().sorted()); groups \(personal.groups.map(\.name))"
        })
        let restored = try #require(personal.group(setup.group))
        #expect(restored.name == setup.name)
        #expect(restored.pinned == setup.pinned)
        #expect(personal.groups.map(\.id) == setup.order, "the group came back in another place: \(personal.groups.map(\.name))")
    }
}
