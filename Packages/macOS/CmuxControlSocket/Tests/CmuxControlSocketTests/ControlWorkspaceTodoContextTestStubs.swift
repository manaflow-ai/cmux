import Foundation
@testable import CmuxControlSocket

// Benign default implementations of the workspace-todo domain seam, so a test
// fake that conforms to the full `ControlCommandContext` umbrella only has to
// implement the domain it actually exercises (the workspace-todo block of
// `ControlCommandContextTestStubs.swift`, split out for the file-length
// budget).

extension ControlWorkspaceTodoContext {
    func controlWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution { .tabManagerUnavailable }

    func controlSetWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        statusRaw: String?
    ) -> ControlWorkspaceTodoStatusResolution { .tabManagerUnavailable }

    func controlCycleWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoList(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoChecklistResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoAdd(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        text: String,
        stateRaw: String?,
        originRaw: String?
    ) -> ControlWorkspaceTodoMutationResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoSetState(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        stateRaw: String
    ) -> ControlWorkspaceTodoMutationResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoEdit(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        text: String
    ) -> ControlWorkspaceTodoMutationResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoRemove(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?
    ) -> ControlWorkspaceTodoMutationResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoMove(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        itemID: UUID?,
        itemIndex: Int?,
        toIndex: Int
    ) -> ControlWorkspaceTodoMutationResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoClear(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoMutationResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoSet(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        items: [ControlWorkspaceTodoSetItemParam]
    ) -> ControlWorkspaceTodoSetResolution { .tabManagerUnavailable }

    func controlWorkspaceTodoOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        requestedFocus: Bool
    ) -> ControlWorkspaceTodoOpenResolution { .tabManagerUnavailable }
}
