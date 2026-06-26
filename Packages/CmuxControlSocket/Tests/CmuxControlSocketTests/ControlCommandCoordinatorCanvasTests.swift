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

    var lastZoomDirection: ControlCanvasZoomDirection?

    func controlCanvasZoom(
        routing: ControlRoutingSelectors,
        direction: ControlCanvasZoomDirection
    ) -> ControlCanvasActionResolution {
        lastZoomDirection = direction
        return actionResolution
    }

    var lastJoin: (surfaceID: UUID, targetSurfaceID: UUID)?
    var lastBreakSurfaceID: UUID?
    var lastSelectTabSurfaceID: UUID?

    func controlCanvasJoin(
        routing: ControlRoutingSelectors,
        surfaceID: UUID,
        targetSurfaceID: UUID
    ) -> ControlCanvasActionResolution {
        lastJoin = (surfaceID, targetSurfaceID)
        return actionResolution
    }

    func controlCanvasBreak(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution {
        lastBreakSurfaceID = surfaceID
        return actionResolution
    }

    func controlCanvasSelectTab(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlCanvasActionResolution {
        lastSelectTabSurfaceID = surfaceID
        return actionResolution
    }

    var lastSetViewport: (centerX: Double, centerY: Double, magnification: Double?)?
    var lastNewPaneType: String?

    func controlCanvasSetViewport(
        routing: ControlRoutingSelectors,
        centerX: Double,
        centerY: Double,
        magnification: Double?
    ) -> ControlCanvasActionResolution {
        lastSetViewport = (centerX, centerY, magnification)
        return actionResolution
    }

    func controlCanvasNewPane(
        routing: ControlRoutingSelectors,
        type: String
    ) -> ControlCanvasActionResolution {
        lastNewPaneType = type
        return actionResolution
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
                    isFocused: true,
                    panelIDs: [surfaceID],
                    selectedPanelID: surfaceID
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
                    "surface_ids": .array([.string(surfaceID.uuidString)]),
                    "surface_refs": .array([.string("surface:1")]),
                    "selected_surface_id": .string(surfaceID.uuidString),
                    "selected_surface_ref": .string("surface:1"),
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

    @Test func setModeAcceptsNiriMode() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .ok(mode: "niri")
        let result = coordinator.handle(request("canvas.set_mode", ["mode": .string("niri")]))
        #expect(context.lastMode == "niri")
        #expect(result == .ok(.object(["mode": .string("niri")])))
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

    @Test func zoomValidatesDirection() {
        let (coordinator, context) = makeCoordinator()
        guard case .err(let code, _, _) = coordinator.handle(
            request("canvas.zoom", ["direction": .string("sideways")])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastZoomDirection == nil)

        context.actionResolution = .ok(mode: "canvas")
        guard case .ok = coordinator.handle(
            request("canvas.zoom", ["direction": .string("in")])
        ) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastZoomDirection == .zoomIn)
    }

    @Test func joinRequiresBothSurfaces() {
        let (coordinator, context) = makeCoordinator()
        let surface = UUID()
        guard case .err(let code, _, _) = coordinator.handle(
            request("canvas.join", ["surface_id": .string(surface.uuidString)])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastJoin == nil)

        context.actionResolution = .ok(mode: "canvas")
        let target = UUID()
        guard case .ok = coordinator.handle(request("canvas.join", [
            "surface_id": .string(surface.uuidString),
            "target_surface_id": .string(target.uuidString),
        ])) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastJoin?.surfaceID == surface)
        #expect(context.lastJoin?.targetSurfaceID == target)
    }

    @Test func breakAndSelectTabPassSurfaceThroughSeam() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .ok(mode: "canvas")
        let surface = UUID()
        guard case .ok = coordinator.handle(
            request("canvas.break", ["surface_id": .string(surface.uuidString)])
        ) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastBreakSurfaceID == surface)

        guard case .ok = coordinator.handle(
            request("canvas.select_tab", ["surface_id": .string(surface.uuidString)])
        ) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastSelectTabSurfaceID == surface)
    }

    @Test func infoSerializesViewportStateWhenPresent() {
        let (coordinator, context) = makeCoordinator()
        context.infoSnapshot = ControlCanvasInfoSnapshot(
            workspaceID: UUID(),
            mode: "canvas",
            panes: [],
            magnification: 1.5,
            centerX: 400,
            centerY: 260
        )
        guard case .ok(.object(let object)) = coordinator.handle(request("canvas.info")) else {
            Issue.record("expected ok object")
            return
        }
        #expect(object["magnification"] == .double(1.5))
        #expect(object["viewport_center"] == .object(["x": .double(400), "y": .double(260)]))
    }

    @Test func infoOmitsViewportStateWhenAbsent() {
        let (coordinator, context) = makeCoordinator()
        context.infoSnapshot = ControlCanvasInfoSnapshot(
            workspaceID: UUID(),
            mode: "splits",
            panes: []
        )
        guard case .ok(.object(let object)) = coordinator.handle(request("canvas.info")) else {
            Issue.record("expected ok object")
            return
        }
        #expect(object["magnification"] == nil)
        #expect(object["viewport_center"] == nil)
    }

    @Test func setViewportRequiresCoordinates() {
        let (coordinator, context) = makeCoordinator()
        guard case .err(let code, _, _) = coordinator.handle(
            request("canvas.set_viewport", ["x": .double(10)])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastSetViewport == nil)
    }

    @Test func setViewportRejectsNonPositiveZoom() {
        let (coordinator, context) = makeCoordinator()
        guard case .err(let code, _, _) = coordinator.handle(
            request("canvas.set_viewport", ["x": .double(10), "y": .double(20), "zoom": .double(0)])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastSetViewport == nil)
    }

    @Test func setViewportPassesCenterAndZoomThroughSeam() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .ok(mode: "canvas")
        guard case .ok = coordinator.handle(request("canvas.set_viewport", [
            "x": .double(400), "y": .double(260), "zoom": .double(1.5),
        ])) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastSetViewport?.centerX == 400)
        #expect(context.lastSetViewport?.centerY == 260)
        #expect(context.lastSetViewport?.magnification == 1.5)
    }

    @Test func setViewportKeepsZoomNilWhenOmitted() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .ok(mode: "canvas")
        guard case .ok = coordinator.handle(request("canvas.set_viewport", [
            "x": .double(0), "y": .double(0),
        ])) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastSetViewport?.magnification == nil)
    }

    @Test func newPaneDefaultsToTerminalAndSerializesCreatedSurface() {
        let (coordinator, context) = makeCoordinator()
        let surface = UUID()
        context.actionResolution = .created(mode: "canvas", surfaceID: surface)
        guard case .ok(.object(let object)) = coordinator.handle(request("canvas.new_pane")) else {
            Issue.record("expected ok object")
            return
        }
        #expect(context.lastNewPaneType == "terminal")
        #expect(object["surface_id"] == .string(surface.uuidString))
        #expect(object["mode"] == .string("canvas"))
    }

    @Test func newPaneRejectsUnknownType() {
        let (coordinator, context) = makeCoordinator()
        guard case .err(let code, _, _) = coordinator.handle(
            request("canvas.new_pane", ["type": .string("widget")])
        ) else {
            Issue.record("expected err")
            return
        }
        #expect(code == "invalid_params")
        #expect(context.lastNewPaneType == nil)
    }

    @Test func newPanePassesBrowserTypeThroughSeam() {
        let (coordinator, context) = makeCoordinator()
        context.actionResolution = .created(mode: "canvas", surfaceID: UUID())
        guard case .ok = coordinator.handle(
            request("canvas.new_pane", ["type": .string("browser")])
        ) else {
            Issue.record("expected ok")
            return
        }
        #expect(context.lastNewPaneType == "browser")
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
