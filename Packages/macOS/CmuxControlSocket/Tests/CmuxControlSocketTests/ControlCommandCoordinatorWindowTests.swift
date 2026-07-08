import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the window coordinator
/// without the app target.
@MainActor
private final class FakeControlCommandContext: ControlCommandContext {
    var windowSummaries: [ControlWindowSummary] = []
    var currentWindowResolution: ControlCurrentWindowResolution = .tabManagerUnavailable
    var lastRouting: ControlRoutingSelectors?
    var focusResult = false
    var focusedID: UUID?
    var createResult: UUID?
    var closeResult = false
    var closedID: UUID?
    var displays: [ControlDisplayInfo] = []
    var existingWindowIDs: Set<UUID> = []
    var moveWindowResult: String?
    var movedWindow: (id: UUID, query: String)?
    var moveAllResult: ControlMoveAllWindowsResult?

    func controlWindowSummaries() -> [ControlWindowSummary] { windowSummaries }

    func controlResolveCurrentWindow(routing: ControlRoutingSelectors) -> ControlCurrentWindowResolution {
        lastRouting = routing
        return currentWindowResolution
    }

    func controlFocusWindow(id: UUID) -> Bool {
        focusedID = id
        return focusResult
    }

    func controlCreateWindowAndActivate() -> UUID? { createResult }

    func controlCloseWindow(id: UUID) -> Bool {
        closedID = id
        return closeResult
    }

    func controlAvailableDisplays() -> [ControlDisplayInfo] { displays }

    func controlWindowExists(id: UUID) -> Bool { existingWindowIDs.contains(id) }

    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? {
        movedWindow = (id, query)
        return moveWindowResult
    }

    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? {
        moveAllResult
    }
}

@MainActor
@Suite("ControlCommandCoordinator window domain")
struct ControlCommandCoordinatorWindowTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeControlCommandContext) {
        let context = FakeControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func unownedMethodFallsThrough() {
        let (coordinator, _) = makeCoordinator()
        // A method no coordinator domain owns (still served by the legacy
        // app-side dispatcher), so `handle` falls through with `nil`.
        #expect(coordinator.handle(request("legacy.unowned_method")) == nil)
    }

    @Test func windowListBuildsRowsWithMintedRefs() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        let workspaceID = UUID()
        context.windowSummaries = [
            ControlWindowSummary(
                windowID: windowID,
                isKeyWindow: true,
                isVisible: true,
                workspaceCount: 3,
                selectedWorkspaceID: workspaceID
            ),
        ]
        let result = coordinator.handle(request("window.list"))
        // First mint of each kind is ordinal 1.
        #expect(result == .ok(.object([
            "windows": .array([
                .object([
                    "id": .string(windowID.uuidString),
                    "ref": .string("window:1"),
                    "index": .int(0),
                    "key": .bool(true),
                    "visible": .bool(true),
                    "workspace_count": .int(3),
                    "selected_workspace_id": .string(workspaceID.uuidString),
                    "selected_workspace_ref": .string("workspace:1"),
                ]),
            ]),
        ])))
    }

    @Test func windowListNilSelectedWorkspaceIsNull() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.windowSummaries = [
            ControlWindowSummary(
                windowID: windowID,
                isKeyWindow: false,
                isVisible: false,
                workspaceCount: 0,
                selectedWorkspaceID: nil
            ),
        ]
        guard case .ok(.object(let payload)) = coordinator.handle(request("window.list")),
              case .array(let rows) = payload["windows"],
              case .object(let row) = rows.first else {
            Issue.record("unexpected shape")
            return
        }
        #expect(row["selected_workspace_id"] == .null)
        #expect(row["selected_workspace_ref"] == .null)
    }

    @Test func windowCurrentResolvesAndMintsRef() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.currentWindowResolution = .resolved(windowID)
        let result = coordinator.handle(request("window.current"))
        #expect(result == .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
        ])))
    }

    @Test func windowCurrentTabManagerUnavailable() {
        let (coordinator, context) = makeCoordinator()
        context.currentWindowResolution = .tabManagerUnavailable
        #expect(coordinator.handle(request("window.current"))
            == .err(code: "unavailable", message: "TabManager not available", data: nil))
    }

    @Test func windowCurrentWindowNotFound() {
        let (coordinator, context) = makeCoordinator()
        context.currentWindowResolution = .windowNotFound
        #expect(coordinator.handle(request("window.current"))
            == .err(code: "not_found", message: "Current window not found", data: nil))
    }

    @Test func windowCurrentParsesRoutingSelectors() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        _ = coordinator.handle(request("window.current", [
            "workspace_id": .string(workspaceID.uuidString),
            "window_id": .null,
        ]))
        #expect(context.lastRouting?.hasWindowIDParam == false)
        #expect(context.lastRouting?.workspaceID == workspaceID)
    }

    @Test func windowFocusOkAndNotFound() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.focusResult = true
        let okResult = coordinator.handle(request("window.focus", ["window_id": .string(windowID.uuidString)]))
        #expect(context.focusedID == windowID)
        #expect(okResult == .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
        ])))

        context.focusResult = false
        let notFound = coordinator.handle(request("window.focus", ["window_id": .string(windowID.uuidString)]))
        #expect(notFound == .err(code: "not_found", message: "Window not found", data: .object([
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
        ])))
    }

    @Test func windowFocusInvalidParams() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handle(request("window.focus"))
            == .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil))
    }

    @Test func windowCreateOkAndFailure() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.createResult = windowID
        #expect(coordinator.handle(request("window.create")) == .ok(.object([
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
        ])))

        context.createResult = nil
        #expect(coordinator.handle(request("window.create"))
            == .err(code: "internal_error", message: "Failed to create window", data: nil))
    }

    @Test func windowCloseOkAndNotFound() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.closeResult = true
        #expect(coordinator.handle(request("window.close", ["window_id": .string(windowID.uuidString)]))
            == .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": .string("window:1"),
            ])))
        #expect(context.closedID == windowID)

        context.closeResult = false
        let notFound = coordinator.handle(request("window.close", ["window_id": .string(windowID.uuidString)]))
        #expect(notFound == .err(code: "not_found", message: "Window not found", data: .object([
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
        ])))
    }

    @Test func windowDisplaysBuildsPayload() {
        let (coordinator, context) = makeCoordinator()
        context.displays = [
            ControlDisplayInfo(
                name: "LG HDR 4K",
                index: 0,
                displayID: 42,
                isMain: true,
                frameX: 0,
                frameY: 0,
                frameWidth: 3840.7,
                frameHeight: 2160.9
            ),
            ControlDisplayInfo(
                name: "Sidecar",
                index: 1,
                displayID: nil,
                isMain: false,
                frameX: -100.4,
                frameY: 12.6,
                frameWidth: 1280,
                frameHeight: 800
            ),
        ]
        #expect(coordinator.handle(request("window.displays")) == .ok(.object([
            "displays": .array([
                .object([
                    "name": .string("LG HDR 4K"),
                    "index": .int(0),
                    "display_id": .int(42),
                    "main": .bool(true),
                    "frame": .object([
                        "x": .int(0), "y": .int(0), "width": .int(3840), "height": .int(2160),
                    ]),
                ]),
                .object([
                    "name": .string("Sidecar"),
                    "index": .int(1),
                    "display_id": .null,
                    "main": .bool(false),
                    "frame": .object([
                        // Int() truncates toward zero, matching Int(frame.origin.x).
                        "x": .int(-100), "y": .int(12), "width": .int(1280), "height": .int(800),
                    ]),
                ]),
            ]),
        ])))
    }

    @Test func windowDisplayMovesSingleWindow() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.moveWindowResult = "LG HDR 4K"
        #expect(coordinator.handle(request("window.display", [
            "display": .string("LG"),
            "window_id": .string(windowID.uuidString),
        ])) == .ok(.object([
            "display": .string("LG HDR 4K"),
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
            "moved": .array([.string(windowID.uuidString)]),
        ])))
        #expect(context.movedWindow?.query == "LG")
    }

    @Test func windowDisplayWindowNotFound() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.moveWindowResult = nil
        context.existingWindowIDs = []
        #expect(coordinator.handle(request("window.display", [
            "display": .string("LG"),
            "window_id": .string(windowID.uuidString),
        ])) == .err(code: "not_found", message: "Window not found", data: .object([
            "window_id": .string(windowID.uuidString),
            "window_ref": .string("window:1"),
        ])))
    }

    @Test func windowDisplayDisplayNotFoundListsAvailable() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        context.moveWindowResult = nil
        context.existingWindowIDs = [windowID]
        context.displays = [
            ControlDisplayInfo(
                name: "Built-in", index: 0, displayID: 1, isMain: true,
                frameX: 0, frameY: 0, frameWidth: 1, frameHeight: 1
            ),
        ]
        #expect(coordinator.handle(request("window.display", [
            "display": .string("Nope"),
            "window_id": .string(windowID.uuidString),
        ])) == .err(code: "not_found", message: "Display not found: Nope", data: .object([
            "requested": .string("Nope"),
            "available": .array([.string("Built-in")]),
        ])))
    }

    @Test func windowDisplayMovesAllWindows() {
        let (coordinator, context) = makeCoordinator()
        let a = UUID()
        let b = UUID()
        context.moveAllResult = ControlMoveAllWindowsResult(display: "LG HDR 4K", windowIDs: [a, b])
        #expect(coordinator.handle(request("window.display", ["display": .string("LG")]))
            == .ok(.object([
                "display": .string("LG HDR 4K"),
                "moved": .array([.string(a.uuidString), .string(b.uuidString)]),
            ])))
    }

    @Test func windowDisplayInvalidParams() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handle(request("window.display"))
            == .err(code: "invalid_params", message: "Missing or invalid display", data: nil))
    }

    @Test func uuidParamResolvesMintedRef() {
        let (coordinator, context) = makeCoordinator()
        let windowID = UUID()
        let ref = coordinator.ensureRef(kind: .window, uuid: windowID)
        context.focusResult = true
        // Passing the ref string instead of the UUID resolves to the same window.
        _ = coordinator.handle(request("window.focus", ["window_id": .string(ref)]))
        #expect(context.focusedID == windowID)
    }
}
