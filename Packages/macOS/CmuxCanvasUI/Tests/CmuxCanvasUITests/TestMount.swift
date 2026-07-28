@testable import CmuxCanvasUI

final class TestMount: CanvasPaneContentMounting {
    var renderingStates: [Bool] = []
    var focusedStates: [Bool] = []
    var inactiveOverlayStates: [Bool] = []

    func setRendering(_ rendering: Bool) {
        renderingStates.append(rendering)
    }

    func recordPresentation(isFocused: Bool, showsInactiveOverlay: Bool) {
        focusedStates.append(isFocused)
        inactiveOverlayStates.append(showsInactiveOverlay)
    }

    func unmount() {}
}
