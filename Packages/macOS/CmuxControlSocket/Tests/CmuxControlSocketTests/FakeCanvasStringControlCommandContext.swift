import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeCanvasStringControlCommandContext: ControlCommandContext {
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
