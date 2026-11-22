#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-22: "if the data was sent through... why cant you simply
/// scroll through the depiction that was already given?" Over a full-screen
/// app one finger reads (sends nothing) and only two fingers scroll the app.
@MainActor
@Suite struct TerminalTUIScrollControllerTests {
    @Test func oneFingerReadsAndTwoFingersScrollTheApp() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let surface = TerminalSurfaceView(frame: host.bounds)
        host.addSubview(surface)
        let tap = UITapGestureRecognizer()
        host.addGestureRecognizer(tap)
        let controller = TerminalTUIScrollController()
        controller.install(in: host, surface: surface, tap: tap)
        let wheel = try #require(controller.pan)
        let read = try #require(controller.readPan)
        #expect(wheel.minimumNumberOfTouches == 2)
        #expect(wheel.maximumNumberOfTouches == 2)
        #expect(read.minimumNumberOfTouches == 1)
        #expect(read.maximumNumberOfTouches == 1)
        // The one-finger pan has no path to the surface's wheel.
        #expect(read.view === host)
    }
}
#endif
