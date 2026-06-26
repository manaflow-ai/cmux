import AppKit
import CmuxCanvas

/// One arranged object in the native Pages strip.
@MainActor
final class CanvasPageObject: NSObject {
    let pane: CanvasPane

    init(pane: CanvasPane) {
        self.pane = pane
        super.init()
    }

    var paneID: CanvasPaneID {
        pane.id
    }

    var selectedPanelId: UUID {
        pane.selectedPanelId.rawValue
    }
}
