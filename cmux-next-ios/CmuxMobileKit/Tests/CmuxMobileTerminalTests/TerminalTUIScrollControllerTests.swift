#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: "surely we're not regressing behavior, right? Like, you
/// can still scroll through things and click on things and whatnot". Over a
/// full-screen app one finger scrolls the app, as at base.
@MainActor
@Suite struct TerminalTUIScrollControllerTests {
    @Test func oneFingerScrollsTheApp() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let surface = TerminalSurfaceView(frame: host.bounds)
        host.addSubview(surface)
        let tap = UITapGestureRecognizer()
        host.addGestureRecognizer(tap)
        let controller = TerminalTUIScrollController()
        controller.install(in: host, surface: surface, tap: tap)
        let wheel = try #require(controller.pan)
        #expect(wheel.minimumNumberOfTouches == 1)
        #expect(wheel.maximumNumberOfTouches == 1)
        #expect(wheel.view === host)
        // The only pan on the host: no one-finger drag that sends nothing.
        #expect(host.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.count == 1)
    }
}
#endif
