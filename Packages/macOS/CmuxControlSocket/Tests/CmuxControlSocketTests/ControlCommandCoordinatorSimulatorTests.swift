import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the simulator
/// coordinator domain without the app target.
@MainActor
private final class FakeSimulatorControlCommandContext: ControlCommandContext {
    var openResolution: ControlSimulatorOpenResolution = .tabManagerUnavailable
    var closeResolution: ControlSimulatorCloseResolution = .tabManagerUnavailable

    var lastOpen: (workspaceID: UUID?, deviceQuery: String, requestedFocus: Bool)?
    var lastClose: (workspaceID: UUID?, surfaceID: UUID?)?

    func controlSimulatorOpen(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        deviceQuery: String,
        requestedFocus: Bool
    ) -> ControlSimulatorOpenResolution {
        lastOpen = (workspaceID, deviceQuery, requestedFocus)
        return openResolution
    }

    func controlSimulatorClose(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        surfaceID: UUID?
    ) -> ControlSimulatorCloseResolution {
        lastClose = (workspaceID, surfaceID)
        return closeResolution
    }

    nonisolated func controlResolveOnMain<T: Sendable>(
        _ body: @MainActor (any ControlCommandContext) -> T
    ) -> T {
        MainActor.assumeIsolated { body(self) }
    }
}

@MainActor
@Suite("ControlCommandCoordinator simulator domain")
struct ControlCommandCoordinatorSimulatorTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSimulatorControlCommandContext) {
        let context = FakeSimulatorControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func openRequiresDeviceParam() throws {
        let (coordinator, context) = makeCoordinator()
        let result = try #require(coordinator.handle(request("simulator.open")))
        guard case .err(let code, _, _) = result else {
            Issue.record("expected error, got \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastOpen == nil)
    }

    @Test func openThreadsDeviceWorkspaceAndFocusAndRepliesWithHandles() throws {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let paneID = UUID()
        context.openResolution = .opened(
            windowID: nil, workspaceID: workspaceID, paneID: paneID, surfaceID: surfaceID
        )
        let result = try #require(coordinator.handle(request("simulator.open", [
            "device": .string("iPhone 17 Pro"),
            "workspace_id": .string(workspaceID.uuidString),
            "focus": .bool(true),
        ])))
        #expect(context.lastOpen?.deviceQuery == "iPhone 17 Pro")
        #expect(context.lastOpen?.workspaceID == workspaceID)
        #expect(context.lastOpen?.requestedFocus == true)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
        #expect(payload["pane_id"] == .string(paneID.uuidString))
    }

    @Test func openDefaultsFocusToFalse() throws {
        let (coordinator, context) = makeCoordinator()
        context.openResolution = .openFailed
        _ = try #require(coordinator.handle(request("simulator.open", [
            "device": .string("iPhone 17 Pro"),
        ])))
        #expect(context.lastOpen?.requestedFocus == false)
    }

    @Test func disabledFeatureRefusesWithGuidance() throws {
        let (coordinator, context) = makeCoordinator()
        context.openResolution = .featureDisabled
        context.closeResolution = .featureDisabled
        for method in ["simulator.open", "simulator.close"] {
            let params: [String: JSONValue] = method == "simulator.open"
                ? ["device": .string("iPhone 17 Pro")]
                : [:]
            let result = try #require(coordinator.handle(request(method, params)))
            guard case .err(let code, let message, _) = result else {
                Issue.record("expected error for \(method), got \(result)")
                continue
            }
            #expect(code == "feature_disabled")
            #expect(message.contains("simulator.beta.enabled"))
        }
    }

    @Test func closeThreadsSurfaceAndRepliesWithHandles() throws {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        context.closeResolution = .closed(workspaceID: workspaceID, surfaceID: surfaceID)
        let result = try #require(coordinator.handle(request("simulator.close", [
            "surface_id": .string(surfaceID.uuidString),
        ])))
        #expect(context.lastClose?.surfaceID == surfaceID)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(result)")
            return
        }
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
    }

    @Test func closeAmbiguityIsAnInvalidParamsError() throws {
        let (coordinator, context) = makeCoordinator()
        context.closeResolution = .ambiguous(count: 2)
        let result = try #require(coordinator.handle(request("simulator.close")))
        guard case .err(let code, let message, _) = result else {
            Issue.record("expected error, got \(result)")
            return
        }
        #expect(code == "invalid_params")
        #expect(message.contains("--surface"))
    }

    @Test func unknownSimulatorMethodFallsThrough() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handle(request("simulator.reboot")) == nil)
    }
}
