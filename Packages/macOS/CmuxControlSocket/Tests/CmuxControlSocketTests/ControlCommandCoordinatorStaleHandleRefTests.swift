import Foundation
import Testing
@testable import CmuxControlSocket

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9410:
/// an explicit target that resolves to nothing must be a hard error, never a
/// silent fall-through to the focused/selected target. For destructive ops
/// (`surface.close`, `surface.respawn`) the fall-through destroys live state.
@MainActor
@Suite("ControlCommandCoordinator unresolvable targets")
struct ControlCommandCoordinatorStaleHandleRefTests {
    @Test func closeSurfaceWithUnknownSurfaceRefErrorsWithoutClosingAnything() {
        let context = RecordingDestructiveSurfaceContext()
        let coordinator = ControlCommandCoordinator(context: context)
        // A live surface exists and holds a ref, so the registry is populated;
        // `surface:99999` still matches nothing.
        let liveSurface = UUID()
        coordinator.ensureRef(kind: .surface, uuid: liveSurface)
        context.closeResolution = .closed(
            windowID: UUID(),
            workspaceID: UUID(),
            surfaceID: liveSurface
        )

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: ["surface_id": .string("surface:99999")]
        ))

        guard case .err(let code, _, _) = result else {
            Issue.record("expected an error for an unknown surface ref, got \(String(describing: result))")
            return
        }
        #expect(code == "not_found")
        #expect(context.closeCalls.isEmpty)
    }

    @Test(arguments: ["surface:not-a-number", "surafce:12", "surface-3", "", "  "])
    func closeSurfaceWithMalformedSurfaceTargetClosesNothing(target: String) {
        let context = RecordingDestructiveSurfaceContext()
        let coordinator = ControlCommandCoordinator(context: context)
        coordinator.ensureRef(kind: .surface, uuid: UUID())
        context.closeResolution = .closed(
            windowID: UUID(),
            workspaceID: UUID(),
            surfaceID: UUID()
        )

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: ["surface_id": .string(target)]
        ))

        // A whitespace-only value reads as absent (legacy `v2String`), so the
        // focused-surface close stays legal there; anything else names a
        // target that cannot be resolved and must not close a bystander.
        if target.trimmingCharacters(in: .whitespaces).isEmpty {
            #expect(context.closeCalls == [nil])
            return
        }
        guard case .err(let code, _, _) = result else {
            Issue.record("expected an error for target '\(target)', got \(String(describing: result))")
            return
        }
        #expect(code == "not_found")
        #expect(context.closeCalls.isEmpty)
    }

    @Test func closeSurfaceWithUnknownWorkspaceRefErrorsWithoutClosingAnything() {
        let context = RecordingDestructiveSurfaceContext()
        let coordinator = ControlCommandCoordinator(context: context)
        coordinator.ensureRef(kind: .workspace, uuid: UUID())

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: ["workspace_id": .string("workspace:99")]
        ))

        guard case .err(let code, _, _) = result else {
            Issue.record("expected an error for an unknown workspace ref, got \(String(describing: result))")
            return
        }
        #expect(code == "not_found")
        #expect(context.closeCalls.isEmpty)
    }

    @Test func respawnWithUnknownSurfaceRefErrorsWithoutRespawningAnything() {
        let context = RecordingDestructiveSurfaceContext()
        let coordinator = ControlCommandCoordinator(context: context)
        coordinator.ensureRef(kind: .surface, uuid: UUID())

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.respawn",
            params: ["surface_id": .string("surface:4242")]
        ))

        guard case .err(let code, _, _) = result else {
            Issue.record("expected an error for an unknown surface ref, got \(String(describing: result))")
            return
        }
        #expect(code == "not_found")
        #expect(context.respawnCalls.isEmpty)
    }

    @Test func closeSurfaceWithKnownRefStillCloses() {
        let context = RecordingDestructiveSurfaceContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let surfaceID = UUID()
        let ref = coordinator.ensureRef(kind: .surface, uuid: surfaceID)
        context.closeResolution = .closed(
            windowID: UUID(),
            workspaceID: UUID(),
            surfaceID: surfaceID
        )

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: ["surface_id": .string(ref)]
        ))

        guard case .ok = result else {
            Issue.record("expected a successful close, got \(String(describing: result))")
            return
        }
        #expect(context.closeCalls == [surfaceID])
    }

    @Test func closeSurfaceWithUnknownUUIDStillReachesTheCommandsOwnNotFound() {
        let context = RecordingDestructiveSurfaceContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let requested = UUID()
        context.closeResolution = .surfaceNotFound(requested)

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: ["surface_id": .string(requested.uuidString)]
        ))

        guard case .err(let code, _, _) = result else {
            Issue.record("expected a not_found error, got \(String(describing: result))")
            return
        }
        #expect(code == "not_found")
        #expect(context.closeCalls == [requested])
    }

    @Test func closeSurfaceWithNoTargetStillUsesFocusedSurface() {
        let context = RecordingDestructiveSurfaceContext()
        let coordinator = ControlCommandCoordinator(context: context)
        context.closeResolution = .closed(
            windowID: UUID(),
            workspaceID: UUID(),
            surfaceID: UUID()
        )

        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "surface.close",
            params: [:]
        ))

        guard case .ok = result else {
            Issue.record("expected a successful close, got \(String(describing: result))")
            return
        }
        #expect(context.closeCalls == [nil])
    }
}
