import AppKit
import Testing
@testable import CmuxAppKitSupportUI
@testable import CmuxCommandPaletteUI

@MainActor
@Suite struct CommandPaletteOverlayContainerViewTests {
    @Test func ignoresHitTestUntilCapturingMouseEvents() {
        let container = CommandPaletteOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let child = NSView(frame: container.bounds)
        container.addSubview(child)

        #expect(container.hitTest(NSPoint(x: 10, y: 10)) == nil)

        container.capturesMouseEvents = true
        #expect(container.hitTest(NSPoint(x: 10, y: 10)) != nil)
    }

    @Test func carriesOverlayContainerIdentifier() {
        #expect(commandPaletteOverlayContainerIdentifier.rawValue == "cmux.commandPalette.overlay.container")
    }

    @Test func passthroughContainerNeverHitTests() {
        let container = PassthroughOverlayContainerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.addSubview(NSView(frame: container.bounds))
        #expect(container.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(container.isOpaque == false)
    }
}
