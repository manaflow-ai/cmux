import Foundation
import Testing
@testable import CmuxControlSocket

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9424 (2):
/// a `kind:N` ref must only resolve for the kind its param key expects.
///
/// `ControlHandleRegistry.uuid(forRef:)` searches every kind, so `group_id:
/// "surface:1"` used to resolve to a surface UUID, fail the group lookup in the
/// routing walk, and fall through to the active window — turning a
/// wrong-kind explicit target into an implicit one.
@MainActor
@Suite("ControlCommandCoordinator routing ref kinds")
struct ControlCommandCoordinatorRoutingKindTests {
    /// The identities behind `window:1`, `workspace:1`, `workspace_group:1`,
    /// `pane:1`, and `surface:1` in a freshly seeded coordinator.
    private typealias Handles = (
        window: UUID, workspace: UUID, group: UUID, pane: UUID, surface: UUID
    )

    /// A coordinator with one minted ref per kind (`window:1`, `workspace:1`,
    /// `workspace_group:1`, `pane:1`, `surface:1`).
    private func coordinatorWithOneRefPerKind() -> (ControlCommandCoordinator, Handles) {
        let coordinator = ControlCommandCoordinator()
        let handles: Handles = (
            window: UUID(), workspace: UUID(), group: UUID(), pane: UUID(), surface: UUID()
        )
        coordinator.ensureRef(kind: .window, uuid: handles.window)
        coordinator.ensureRef(kind: .workspace, uuid: handles.workspace)
        coordinator.ensureRef(kind: .workspaceGroup, uuid: handles.group)
        coordinator.ensureRef(kind: .pane, uuid: handles.pane)
        coordinator.ensureRef(kind: .surface, uuid: handles.surface)
        return (coordinator, handles)
    }

    @Test func wrongKindRefsDoNotResolveAsRoutingSelectors() {
        let (coordinator, _) = coordinatorWithOneRefPerKind()

        #expect(coordinator.routingSelectors(["group_id": .string("surface:1")]).groupID == nil)
        #expect(coordinator.routingSelectors(["group_id": .string("workspace:1")]).groupID == nil)
        #expect(coordinator.routingSelectors(["pane_id": .string("workspace:1")]).paneID == nil)
        #expect(coordinator.routingSelectors(["workspace_id": .string("pane:1")]).workspaceID == nil)
        #expect(coordinator.routingSelectors(["surface_id": .string("pane:1")]).surfaceID == nil)

        // A present-but-wrong-kind window_id must stay "present, unresolvable"
        // so the routing walk fails closed instead of falling through.
        let windowRouting = coordinator.routingSelectors(["window_id": .string("surface:1")])
        #expect(windowRouting.hasWindowIDParam)
        #expect(windowRouting.windowID == nil)
    }

    @Test func rightKindRefsStillResolve() {
        let (coordinator, handles) = coordinatorWithOneRefPerKind()

        #expect(coordinator.routingSelectors(["window_id": .string("window:1")]).windowID == handles.window)
        #expect(
            coordinator.routingSelectors(["workspace_id": .string("workspace:1")]).workspaceID
                == handles.workspace
        )
        #expect(
            coordinator.routingSelectors(["group_id": .string("workspace_group:1")]).groupID
                == handles.group
        )
        #expect(coordinator.routingSelectors(["pane_id": .string("pane:1")]).paneID == handles.pane)
        #expect(
            coordinator.routingSelectors(["surface_id": .string("surface:1")]).surfaceID
                == handles.surface
        )
    }

    @Test func protocolAliasesStayAccepted() {
        let (coordinator, handles) = coordinatorWithOneRefPerKind()

        // `tab:N` is the wire alias for `surface:N` in tab-facing APIs.
        #expect(coordinator.routingSelectors(["surface_id": .string("tab:1")]).surfaceID == handles.surface)
        #expect(coordinator.routingSelectors(["tab_id": .string("tab:1")]).surfaceID == handles.surface)
        #expect(coordinator.routingSelectors(["terminal_id": .string("surface:1")]).surfaceID == handles.surface)

        // The Window Dock passes a *window* identity as `workspace_id`.
        #expect(
            coordinator.routingSelectors(["workspace_id": .string("window:1")]).workspaceID
                == handles.window
        )
    }

    /// A raw UUID string bypasses `kind:N` parsing entirely, so kind checking
    /// has to happen for it too whenever the registry already knows what that
    /// identity is. A surface UUID handed to `group_id` is provably wrong-kind.
    @Test func rawUUIDsOfAKnownWrongKindDoNotResolve() {
        let (coordinator, handles) = coordinatorWithOneRefPerKind()

        #expect(coordinator.routingSelectors(["group_id": .string(handles.surface.uuidString)]).groupID == nil)
        #expect(coordinator.routingSelectors(["group_id": .string(handles.workspace.uuidString)]).groupID == nil)
        #expect(coordinator.routingSelectors(["pane_id": .string(handles.surface.uuidString)]).paneID == nil)
        #expect(coordinator.routingSelectors(["surface_id": .string(handles.pane.uuidString)]).surfaceID == nil)
        #expect(coordinator.routingSelectors(["workspace_id": .string(handles.pane.uuidString)]).workspaceID == nil)

        let windowRouting = coordinator.routingSelectors(["window_id": .string(handles.surface.uuidString)])
        #expect(windowRouting.hasWindowIDParam)
        #expect(windowRouting.windowID == nil)
    }

    @Test func rawUUIDsOfTheRightKindStillResolve() {
        let (coordinator, handles) = coordinatorWithOneRefPerKind()

        #expect(
            coordinator.routingSelectors(["group_id": .string(handles.group.uuidString)]).groupID
                == handles.group
        )
        #expect(
            coordinator.routingSelectors(["surface_id": .string(handles.surface.uuidString)]).surfaceID
                == handles.surface
        )
        #expect(coordinator.routingSelectors(["pane_id": .string(handles.pane.uuidString)]).paneID == handles.pane)
        // The Window Dock passes a window identity as workspace_id.
        #expect(
            coordinator.routingSelectors(["workspace_id": .string(handles.window.uuidString)]).workspaceID
                == handles.window
        )
    }

    /// A UUID the registry has never minted has no known kind, so it still
    /// passes through. That is gap 1 of the issue (the caller-injected
    /// `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` context problem), which needs a
    /// product call on the wire format before it can fail closed.
    @Test func unmintedRawUUIDsStillPassThrough() {
        let (coordinator, _) = coordinatorWithOneRefPerKind()
        let stranger = UUID()

        #expect(coordinator.routingSelectors(["group_id": .string(stranger.uuidString)]).groupID == stranger)
        #expect(coordinator.routingSelectors(["surface_id": .string(stranger.uuidString)]).surfaceID == stranger)
    }

    /// Non-routing target keys resolved through the same helper need the kind
    /// they actually mean: `return_to` is a surface, while `from_tab_id` and
    /// `to_tab_id` are workspaces despite the name (they are matched against a
    /// window's workspace list).
    @Test func secondaryTargetKeysUseTheKindTheyActuallyMean() {
        let (coordinator, handles) = coordinatorWithOneRefPerKind()

        #expect(coordinator.resolveIdentifier("surface:1", forParamKey: "return_to") == handles.surface)
        #expect(coordinator.resolveIdentifier("workspace:1", forParamKey: "return_to") == nil)

        for key in ["from_tab_id", "to_tab_id"] {
            #expect(coordinator.resolveIdentifier("workspace:1", forParamKey: key) == handles.workspace)
            #expect(coordinator.resolveIdentifier("surface:1", forParamKey: key) == nil)
        }
    }

    /// The Window Dock alias belongs to the routing `workspace_id` only. The
    /// ordering/reference workspace keys take part in no aliasing, so a window
    /// identity is wrong-kind there.
    @Test func onlyRoutingWorkspaceIDTakesTheWindowAlias() {
        let (coordinator, handles) = coordinatorWithOneRefPerKind()

        #expect(coordinator.resolveIdentifier("window:1", forParamKey: "workspace_id") == handles.window)
        for key in [
            "reference_workspace_id", "group_reference_workspace_id",
            "before_workspace_id", "after_workspace_id",
        ] {
            #expect(coordinator.resolveIdentifier("window:1", forParamKey: key) == nil)
            #expect(coordinator.resolveIdentifier("workspace:1", forParamKey: key) == handles.workspace)
        }
    }

    @Test func registryRejectsRefsOutsideTheRequestedKinds() {
        var registry = ControlHandleRegistry()
        let surfaceID = UUID()
        let paneID = UUID()
        _ = registry.ensureRef(kind: .surface, uuid: surfaceID)
        _ = registry.ensureRef(kind: .pane, uuid: paneID)

        #expect(registry.uuid(forRef: "surface:1", kinds: [.surface]) == surfaceID)
        #expect(registry.uuid(forRef: "tab:1", kinds: [.surface]) == surfaceID)
        #expect(registry.uuid(forRef: "surface:1", kinds: [.pane]) == nil)
        #expect(registry.uuid(forRef: "tab:1", kinds: [.pane]) == nil)
        #expect(registry.uuid(forRef: "pane:1", kinds: [.pane, .surface]) == paneID)
        #expect(registry.uuid(forRef: "pane:1", kinds: []) == nil)
        // The unrestricted overload is unchanged for kind-agnostic callers.
        #expect(registry.uuid(forRef: "pane:1") == paneID)
    }
}
