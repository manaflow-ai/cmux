import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable window seam for `sidebar.group_by`: one window whose mode the
/// fake stores, validating modes the way the app does.
@MainActor
private final class FakeSidebarGroupByContext: ControlCommandContext {
    var windowID = UUID()
    var mode = "manual"
    var resolvesTabManager = true
    var focusedWindowCount = 0
    var lastRouting: ControlRoutingSelectors?
    var lastRequestedMode: String??

    func controlSidebarGroupBy(routing: ControlRoutingSelectors, mode: String?) -> ControlSidebarGroupByResolution {
        lastRouting = routing
        lastRequestedMode = .some(mode)
        guard resolvesTabManager else { return .tabManagerUnavailable }
        if let mode {
            guard ["manual", "host", "status"].contains(mode) else { return .invalidMode }
            self.mode = mode
        }
        return .resolved(windowID: windowID, mode: self.mode)
    }

    func controlFocusWindow(id: UUID) -> Bool {
        focusedWindowCount += 1
        return true
    }
}

@MainActor
@Suite("ControlCommandCoordinator sidebar.group_by")
struct ControlCommandCoordinatorSidebarGroupByTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSidebarGroupByContext) {
        let context = FakeSidebarGroupByContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "sidebar.group_by", params: params)
    }

    @Test func readsCurrentModeWithoutChangingIt() {
        let (coordinator, context) = makeCoordinator()
        context.mode = "status"
        let result = coordinator.handle(request())
        #expect(result == .ok(.object([
            "window_id": .string(context.windowID.uuidString),
            "window_ref": .string("window:1"),
            "mode": .string("status"),
        ])))
        #expect(context.lastRequestedMode == .some(nil))
        #expect(context.mode == "status")
    }

    @Test func setsModeCaseInsensitivelyOnTheRoutedWindowWithoutFocusing() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request([
            "mode": .string(" Host "),
            "window_id": .string(context.windowID.uuidString),
        ]))
        #expect(context.mode == "host")
        #expect(context.lastRouting?.windowID == context.windowID)
        #expect(context.focusedWindowCount == 0)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected ok payload, got \(String(describing: result))")
            return
        }
        #expect(payload["mode"] == .string("host"))
    }

    @Test func unknownModeIsRejectedAndLeavesTheWindowUnchanged() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request(["mode": .string("project")]))
        #expect(result == .err(
            code: "invalid_params",
            message: "Unknown mode; expected manual, host or status",
            data: .object(["mode": .string("project")])
        ))
        #expect(context.mode == "manual")
    }

    @Test func nonStringModeIsInvalidParams() {
        let (coordinator, context) = makeCoordinator()
        let result = coordinator.handle(request(["mode": .int(2)]))
        #expect(result == .err(
            code: "invalid_params",
            message: "mode must be one of manual, host, status",
            data: nil
        ))
        #expect(context.lastRouting == nil)
    }

    @Test func emptyModeIsInvalidParams() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handle(request(["mode": .string("  ")]))
            == .err(code: "invalid_params", message: "mode must be one of manual, host, status", data: nil))
        #expect(context.lastRouting == nil)
    }

    @Test func unresolvedWindowReportsUnavailable() {
        let (coordinator, context) = makeCoordinator()
        context.resolvesTabManager = false
        #expect(coordinator.handle(request(["mode": .string("host")]))
            == .err(code: "unavailable", message: "TabManager not available", data: nil))
    }
}
