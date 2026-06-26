import AppKit
@testable import CmuxCanvasUI

@MainActor
final class FakeMount: CanvasPaneContentMounting {
    private let probe: MountProbe
    private weak var container: NSView?

    init(container: NSView, probe: MountProbe) {
        self.container = container
        self.probe = probe
    }

    func setRendering(_ rendering: Bool) {
        probe.renderStates.append(rendering)
    }

    func unmount() {
        probe.unmountCount += 1
        container = nil
    }
}
