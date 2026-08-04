import AppKit

@MainActor
final class SimulatorVisibilityTestWindow: NSWindow {
    var reportedIsVisible = true
    var reportedIsKeyWindow = false
    var reportedOcclusionState: NSWindow.OcclusionState = []

    override var isVisible: Bool { reportedIsVisible }
    override var isKeyWindow: Bool { reportedIsKeyWindow }
    override var isMiniaturized: Bool { false }
    override var occlusionState: NSWindow.OcclusionState { reportedOcclusionState }
}
