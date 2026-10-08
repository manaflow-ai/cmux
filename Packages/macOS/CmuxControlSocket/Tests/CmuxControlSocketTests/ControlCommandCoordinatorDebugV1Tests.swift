import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
/// A scriptable ``ControlDebugContext`` for driving the v1 debug dispatch
/// without the app target. Only the debug methods the v1 dispatch exercises are
/// overridden; the rest fall back to the benign defaults in
/// `ControlCommandContextTestStubs+Debug.swift`.
@MainActor
private final class FakeDebugV1ControlCommandContext: ControlCommandContext {
    var setShortcutArguments: String?
    var setShortcutResponse = "OK"

    var rightSidebarMode: String??
    var rightSidebarFocusFirstItem: Bool?
    var rightSidebarResolution: ControlDebugRightSidebarFocusResolution = .windowNotFound
    var remoteTmuxSizingPayload: JSONValue?

    func controlDebugSetShortcut(arguments: String) -> String {
        setShortcutArguments = arguments
        return setShortcutResponse
    }

    func controlDebugRightSidebarFocus(
        modeName: String?,
        windowID: UUID?,
        focusFirstItem: Bool
    ) -> ControlDebugRightSidebarFocusResolution {
        rightSidebarMode = modeName
        rightSidebarFocusFirstItem = focusFirstItem
        return rightSidebarResolution
    }

    func controlDebugRemoteTmuxSizingSettled() -> JSONValue? {
        remoteTmuxSizingPayload
    }
}

@MainActor
private final class FakeCommandPaletteControlContext: ControlCommandContext {
    let windowID = UUID()
    var visible = false
    var toggleCalls = 0

    func controlCommandPaletteState(windowID: UUID?) -> (windowID: UUID, visible: Bool)? {
        guard windowID == nil || windowID == self.windowID else { return nil }
        return (self.windowID, visible)
    }

    func controlCommandPaletteToggle(windowID: UUID?) -> Bool {
        guard windowID == nil || windowID == self.windowID else { return false }
        toggleCalls += 1
        visible.toggle()
        return true
    }
}

@MainActor
@Suite("ControlCommandCoordinator debug v1 dispatch")
struct ControlCommandCoordinatorDebugV1Tests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeDebugV1ControlCommandContext) {
        let context = FakeDebugV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    @Test func paletteRejectsMalformedWindowID() {
        let context = FakeCommandPaletteControlContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let request = ControlRequest(
            id: .int(1),
            method: "command_palette.toggle",
            params: ["window_id": .string("not-a-window")]
        )
        #expect(coordinator.handle(request) == .err(
            code: "invalid_params",
            message: "Missing or invalid window_id",
            data: nil
        ))
        #expect(context.toggleCalls == 0)
    }

    @Test func paletteReceiptIncludesResolvedVisibility() {
        let context = FakeCommandPaletteControlContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let request = ControlRequest(id: .int(1), method: "command_palette.toggle", params: [:])
        let reply = coordinator.handle(request)
        guard case .ok(.object(let payload)) = reply else {
            Issue.record("command_palette.toggle did not return an object receipt: \(String(describing: reply))")
            return
        }
        #expect(payload["window_id"] == .string(context.windowID.uuidString))
        #expect(payload["visible"] == .bool(true))
        #expect(context.toggleCalls == 1)
    }

    @Test func forwardsSetShortcutArgumentsVerbatim() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "set_shortcut", args: "open-palette cmd+k")
        #expect(reply == "OK")
        #expect(context.setShortcutArguments == "open-palette cmd+k")
    }

    @Test func forwardsSetShortcutErrorVerbatim() {
        let (coordinator, context) = makeCoordinator()
        context.setShortcutResponse = "ERROR: Invalid shortcut"
        let reply = coordinator.handleDebugV1(command: "set_shortcut", args: "x")
        #expect(reply == "ERROR: Invalid shortcut")
    }

    @Test func unknownCommandFallsThrough() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handleDebugV1(command: "ping", args: "") == nil)
        #expect(coordinator.handleDebugV1(command: "simulate_type", args: "hi") == nil)
        #expect(coordinator.handleDebugV1(command: "screenshot", args: "") == nil)

        let screenshotRequest = ControlRequest(
            id: .int(1),
            method: "debug.window.screenshot",
            params: [:]
        )
        #expect(coordinator.handle(screenshotRequest) == nil)
        #expect(
            ControlCommandExecutionPolicy(forMethod: screenshotRequest.method)
                == .socketWorker(mainThreadCallable: false)
        )
    }

    @Test func remoteTmuxSizingSettlementUsesMainActorDebugSeam() {
        let (coordinator, context) = makeCoordinator()
        let payload: JSONValue = .object([
            "windows": .array([.object(["window": .int(7), "settled": .bool(true)])]),
        ])
        context.remoteTmuxSizingPayload = payload
        let request = ControlRequest(
            id: .int(1), method: "remote.tmux.sizing_settled", params: [:]
        )
        #expect(coordinator.handle(request) == .ok(payload))
        #expect(ControlCommandExecutionPolicy(forMethod: request.method) == .mainActor)
    }

    @Test func rightSidebarFocusInvalidModeReproducesLegacyString() {
        let (coordinator, context) = makeCoordinator()
        context.rightSidebarResolution = .invalidMode("bogus")
        let reply = coordinator.handleDebugV1(command: "debug_right_sidebar_focus", args: "  bogus  ")
        // The v1 body trims the mode argument before validating.
        #expect(context.rightSidebarMode == .some("bogus"))
        // The v1 body never focuses the first item.
        #expect(context.rightSidebarFocusFirstItem == false)
        #expect(reply == "ERROR: Invalid right sidebar mode: bogus")
    }

    @Test func rightSidebarFocusEmptyArgsPassesNilModeForDockDefault() {
        let (coordinator, context) = makeCoordinator()
        context.rightSidebarResolution = .revealed(ControlDebugRightSidebarFocusState(
            revealed: true,
            focusApplied: false,
            contextFound: true,
            stateFound: true,
            visible: true,
            activeMode: "dock",
            mode: "dock"
        ))
        let reply = coordinator.handleDebugV1(command: "debug_right_sidebar_focus", args: "   ")
        // Empty argument maps to nil so the app resolves its `dock` default.
        #expect(context.rightSidebarMode == .some(nil))
        #expect(reply == "OK: mode=dock active=dock visible=1 context=1 state=1 focus=0")
    }

    @Test func rightSidebarFocusUnrevealedReproducesLegacyErrorString() {
        let (coordinator, context) = makeCoordinator()
        context.rightSidebarResolution = .revealed(ControlDebugRightSidebarFocusState(
            revealed: false,
            focusApplied: false,
            contextFound: false,
            stateFound: false,
            visible: false,
            activeMode: nil,
            mode: "split"
        ))
        let reply = coordinator.handleDebugV1(command: "debug_right_sidebar_focus", args: "split")
        #expect(reply == "ERROR: mode=split active= visible=0 context=0 state=0 focus=0")
    }
}
#endif
