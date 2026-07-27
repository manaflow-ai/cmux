import AppKit
import Testing

@testable import CmuxSimulatorUI

@Suite("Remote frame hit testing")
@MainActor
struct CmuxRemoteFrameViewHitTestingTests {
    @Test("Read-only frame presentation leaves pointer input to its host")
    func framePresentationPassesPointerInputToHost() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let frameView = CmuxRemoteFrameView(frame: host.bounds)
        host.addSubview(frameView)

        #expect(host.hitTest(NSPoint(x: 200, y: 150)) === host)
    }
}
