import Foundation
import Testing
@testable import CmuxControlSocket

// Surface-domain default for fakes that do not drive the TextBox. Kept beside its
// tests because `ControlCommandContextTestStubs.swift` is over its line budget.
extension ControlSurfaceContext {
    func controlSurfaceTextBox(
        action: ControlSurfaceTextBoxAction,
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        focusRequested: Bool
    ) -> ControlSurfaceTextBoxResolution { .tabManagerUnavailable }
}

@MainActor
private final class TextBoxControlContext: ControlCommandContext {
    struct Call: Equatable {
        let action: ControlSurfaceTextBoxAction
        let workspaceID: UUID?
        let surfaceID: UUID?
        let hasSurfaceIDParam: Bool
        let focusRequested: Bool
    }

    var resolvesTabManager = true
    var resolution: ControlSurfaceTextBoxResolution = .tabManagerUnavailable
    private(set) var calls: [Call] = []

    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolvesTabManager
    }

    func controlSurfaceTextBox(
        action: ControlSurfaceTextBoxAction,
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        focusRequested: Bool
    ) -> ControlSurfaceTextBoxResolution {
        calls.append(Call(
            action: action,
            workspaceID: routing.workspaceID,
            surfaceID: surfaceID,
            hasSurfaceIDParam: hasSurfaceIDParam,
            focusRequested: focusRequested
        ))
        return resolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator surface.textbox.*")
struct ControlCommandCoordinatorSurfaceTextBoxTests {
    private func run(
        _ method: String,
        params: [String: JSONValue] = [:],
        context: TextBoxControlContext
    ) throws -> ControlCallResult {
        let coordinator = ControlCommandCoordinator(context: context)
        return try #require(coordinator.handle(ControlRequest(id: .int(1), method: method, params: params)))
    }

    @Test(arguments: ControlSurfaceTextBoxAction.allCases)
    func routesEachMethodToItsActionWithTheNamedSurface(action: ControlSurfaceTextBoxAction) throws {
        let context = TextBoxControlContext()
        let workspaceID = UUID()
        let surfaceID = UUID()
        context.resolution = .applied(
            windowID: nil,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            visible: true,
            changed: action != .state
        )
        let result = try run(
            "surface.textbox.\(action.rawValue)",
            params: [
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
            ],
            context: context
        )
        #expect(context.calls == [.init(
            action: action,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            hasSurfaceIDParam: true,
            focusRequested: false
        )])
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected an ok payload, got \(result)")
            return
        }
        #expect(payload["surface_id"] == .string(surfaceID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["window_id"] == .null)
        #expect(payload["visible"] == .bool(true))
        #expect(payload["changed"] == .bool(action != .state))
        #expect(payload["surface_ref"] != nil)
    }

    @Test func passesFocusOnlyForActionsThatShowTheTextBox() throws {
        for (action, expectedFocus) in [
            (ControlSurfaceTextBoxAction.toggle, true),
            (.show, true),
            (.hide, false),
            (.state, false),
        ] {
            let context = TextBoxControlContext()
            _ = try run(action.method, params: ["focus": .bool(true)], context: context)
            #expect(context.calls.map(\.focusRequested) == [expectedFocus], "\(action)")
        }
    }

    @Test func anUnresolvableSurfaceIDIsReportedAsPresent() throws {
        let context = TextBoxControlContext()
        context.resolution = .surfaceNotFoundForID
        let result = try run(
            "surface.textbox.toggle",
            params: ["surface_id": .string("surface:999")],
            context: context
        )
        #expect(context.calls.first?.surfaceID == nil)
        #expect(context.calls.first?.hasSurfaceIDParam == true)
        #expect(result == .err(
            code: "not_found",
            message: "Surface not found for the given surface_id",
            data: nil
        ))
    }

    @Test func aBrowserSurfaceIsRejectedWithItsID() throws {
        let context = TextBoxControlContext()
        let surfaceID = UUID()
        context.resolution = .surfaceNotTerminal(surfaceID)
        let result = try run("surface.textbox.show", context: context)
        #expect(result == .err(
            code: "invalid_params",
            message: "Surface is not a terminal",
            data: .object(["surface_id": .string(surfaceID.uuidString)])
        ))
    }

    @Test func reportsUnavailableWhenDockFocusCannotBeApplied() throws {
        let context = TextBoxControlContext()
        context.resolution = .dockUnavailable(message: "Dock could not be revealed")
        let result = try run("surface.textbox.show", params: ["focus": .bool(true)], context: context)
        #expect(result == .err(code: "unavailable", message: "Dock could not be revealed", data: nil))
    }

    @Test func reportsUnavailableBeforeAskingTheApp() throws {
        let context = TextBoxControlContext()
        context.resolvesTabManager = false
        let result = try run("surface.textbox.hide", context: context)
        #expect(context.calls.isEmpty)
        #expect(result == .err(code: "unavailable", message: "TabManager not available", data: nil))
    }

    @Test func otherTextBoxMethodNamesAreNotHandled() {
        #expect(ControlSurfaceTextBoxAction(method: "surface.textbox.open") == nil)
        #expect(ControlSurfaceTextBoxAction(method: "surface.textbox") == nil)
        #expect(ControlSurfaceTextBoxAction(method: "surface.toggle") == nil)
        #expect(ControlSurfaceTextBoxAction(method: "surface.textbox.toggle") == .toggle)
    }
}
