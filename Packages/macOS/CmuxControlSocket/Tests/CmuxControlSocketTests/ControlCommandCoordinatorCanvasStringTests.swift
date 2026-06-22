import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
private final class FakeCanvasStringControlCommandContext: ControlCommandContext {
    var actionResolution: ControlCanvasActionResolution = .tabManagerUnavailable
    var canvasStrings = ControlCanvasStrings(
        invalidMode: "app invalid mode",
        notCanvasOrZoomable: "app not canvas or zoomable",
        requiresFreeformCanvas: "app requires freeform canvas"
    )

    func controlCanvasStrings() -> ControlCanvasStrings {
        canvasStrings
    }

    func controlCanvasToggleOverview(
        routing: ControlRoutingSelectors
    ) -> ControlCanvasActionResolution {
        actionResolution
    }

    func controlCanvasAlign(
        routing: ControlRoutingSelectors,
        command: ControlCanvasAlignCommand
    ) -> ControlCanvasActionResolution {
        actionResolution
    }
}

@MainActor
@Suite("ControlCommandCoordinator canvas localized strings")
struct ControlCommandCoordinatorCanvasStringTests {
    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    @Test func canvasErrorsUseAppProvidedStrings() {
        let context = FakeCanvasStringControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        guard case .err(_, let invalidModeMessage, _) = coordinator.handle(
            request("canvas.set_mode", ["mode": .string("sideways")])
        ) else {
            Issue.record("expected app-provided invalid mode message")
            return
        }
        #expect(invalidModeMessage == "app invalid mode")

        context.actionResolution = .notCanvasMode
        guard case .err(_, let notCanvasMessage, _) = coordinator.handle(
            request("canvas.overview")
        ) else {
            Issue.record("expected app-provided active viewport message")
            return
        }
        #expect(notCanvasMessage == "app not canvas or zoomable")

        context.actionResolution = .notFreeformCanvasMode
        guard case .err(_, let freeformCanvasMessage, _) = coordinator.handle(
            request("canvas.align", ["command": .string("tidy")])
        ) else {
            Issue.record("expected app-provided freeform canvas message")
            return
        }
        #expect(freeformCanvasMessage == "app requires freeform canvas")
    }
}
