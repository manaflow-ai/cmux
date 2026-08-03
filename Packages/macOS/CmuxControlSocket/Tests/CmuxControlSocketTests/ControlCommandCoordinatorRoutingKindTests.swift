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
    private struct Handles {
        var window = UUID()
        var workspace = UUID()
        var group = UUID()
        var pane = UUID()
        var surface = UUID()
    }

    /// A coordinator with one minted ref per kind (`window:1`, `workspace:1`,
    /// `workspace_group:1`, `pane:1`, `surface:1`).
    private func coordinatorWithOneRefPerKind() -> (ControlCommandCoordinator, Handles) {
        let coordinator = ControlCommandCoordinator()
        let handles = Handles()
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
