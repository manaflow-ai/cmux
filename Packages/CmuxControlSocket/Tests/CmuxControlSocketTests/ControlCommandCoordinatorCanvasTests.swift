import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the canvas coordinator
/// without the app target.
@MainActor
private final class FakeCanvasControlCommandContext: ControlCommandContext {
    var infoSnapshot: ControlCanvasInfoSnapshot?
    var actionResolution: ControlCanvasActionResolution = .tabManagerUnavailable
    var lastMode: String?
    var lastFrame: (surfaceID: UUID, frame: ControlCanvasFrame)?
    var lastAlignCommand: ControlCanvasAlignCommand?
    var lastRevealSurfaceID: UUID??

    func controlCanvasInfo(routing: ControlRoutingSelectors) -> ControlCanvasInfoSnapshot? {
        infoSnapshot
    }

    func controlCanvasSetMode(
        routing: ControlRoutingSelectors,
        mode: String
    ) -> ControlCanvasActionResolution {
        lastMode = mode
        return actionResolution
    }

    func controlCanvasSetFrame(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        frame: ControlCanvasFrame
    ) -> ControlCanvasActionResolution {
        lastFrame = (surfaceID, frame)
        return actionResolution
    }

    func controlCanvasAlign(
        routing: ControlRoutingSelectors,
        command: ControlCanvasAlignCommand
    ) -> ControlCanvasActionResolution {
        lastAlignCommand = command
        return actionResolution
    }

    func controlCanvasReveal(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlCanvasActionResolution {
        lastRevealSurfaceID = surfaceID
        return actionResolution
    }

    func controlCanvasToggleOverview(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution {
        actionResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator canvas domain")
struct ControlCommandCoordinatorCanvasTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeCanvasControlCommandContext) {
        let context = FakeCanvasControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func infoReturnsModeAndZOrderedPanes() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let surfaceID = UUID()
        context.infoSnapshot = ControlCanvasInfoSnapshot(
            workspaceID: workspaceID,
            mode: "canvas",
            panes: [
                ControlCanvasPaneSummary(
                    surfaceID: surfaceID,
                    frame: ControlCanvasFrame(x: 10, y: 20, width: 800, height: 520),
                    isFocused: true
                ),
            ]
        )
        let result = coordinator.handle(request("canvas.info"))
        // First mint of each kind is ordinal 1.
        #expect(result == .ok(.object([
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": .string("workspace:1"),
            "mode": .string("canvas"),
            "panes": .array([
                .object([
                    "surface_id": .string(surfaceID.uuidString),
                    "surface_ref": .string("surface:1"),
                    "x": .double(10),
                    "y": .double(20),
                    "width": .double(800),
                    "height": .double(520),
                    "focused": .bool(true),
                ]),
            ]),
        ])))
    }

    @Test func setModeRejectsUnknownMode() {
        let (coordinator, context) = makeCoordinator()
        guard case .err(let code, _, _) = coordinator.handle(
            request("canvas.set_mode", ["mode": .string("sideways")])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastMode == nil)
    }

    @Test func setModePassesValidatedModeThroughSeam() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .ok(mode: "canvas")
        let result = coordinator.handle(request("canvas.set_mode", ["mode": .string("toggle")]))
        #expect(context.lastMode == "toggle")
        #expect(result == .ok(.object(["mode": .string("canvas")])))
    }

    @Test func setFrameRequiresSurfaceAndPositiveSize() {
        let (coordinator, context) = makeCoordinator()
        let surfaceID = UUID()

        guard case .err(let missingSurface, _, _) = coordinator.handle(
            request("canvas.set_frame", ["x": .double(0), "y": .double(0), "width": .double(10), "height": .double(10)])
        ) else {
            Issue.record("expected err for missing surface")
            return
        }
        #expect(missingSurface == "invalid_params")

        guard case .err(let badSize, _, _) = coordinator.handle(
            request("canvas.set_frame", [
                "surface_id": .string(surfaceID.uuidString),
                "x": .double(0), "y": .double(0), "width": .double(0), "height": .double(10),
            ])
        ) else {
            Issue.record("expected err for zero width")
            return
        }
        #expect(badSize == "invalid_params")
        #expect(context.lastFrame == nil)
    }

    @Test func setFramePassesFrameThroughSeam() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .ok(mode: "canvas")
        let surfaceID = UUID()
        let result = coordinator.handle(request("canvas.set_frame", [
            "surface_id": .string(surfaceID.uuidString),
            "x": .double(40), "y": .double(60), "width": .double(800), "height": .double(520),
        ]))
        guard case .ok = result else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastFrame?.surfaceID == surfaceID)
        #expect(context.lastFrame?.frame == ControlCanvasFrame(x: 40, y: 60, width: 800, height: 520))
    }

    @Test func alignValidatesCommandVocabulary() {
        let (coordinator, context) = makeCoordinator()
        guard case .err(let code, _, _) = coordinator.handle(
            request("canvas.align", ["command": .string("diagonal")])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")

        context.actionResolution = .ok(mode: "canvas")
        guard case .ok = coordinator.handle(
            request("canvas.align", ["command": .string("equalize-widths")])
        ) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastAlignCommand == .equalizeWidths)
    }

    @Test func notCanvasModeMapsToInvalidState() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .notCanvasMode
        guard case .err(let code, _, _) = coordinator.handle(request("canvas.overview")) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_state")
    }

    @Test func paneNotFoundMapsToNotFoundWithSurfaceData() {
        let (coordinator, context) = makeCoordinator()
        let missing = UUID()
        context.actionResolution = .paneNotFound(missing)
        guard case .err(let code, _, let data) = coordinator.handle(
            request("canvas.reveal", ["surface_id": .string(missing.uuidString)])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "not_found")
        #expect(data == .object(["surface_id": .string(missing.uuidString)]))
    }
}
