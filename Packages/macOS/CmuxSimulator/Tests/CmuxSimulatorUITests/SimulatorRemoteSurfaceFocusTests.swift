import AppKit
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator remote surface focus")
@MainActor
struct SimulatorRemoteSurfaceFocusTests {
    @Test("A pre-window focus request is fulfilled after window attachment")
    func pendingFocusSurvivesWindowAttachment() {
        let view = SimulatorRemoteSurfaceView()
        view.requestFocus(generation: 1)

        #expect(view.window == nil)
        #expect(view.pendingFocusGeneration == 1)
        #expect(view.handledFocusGeneration == 0)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        #expect(window.firstResponder === view)
        #expect(view.pendingFocusGeneration == nil)
        #expect(view.handledFocusGeneration == 1)
    }
}
