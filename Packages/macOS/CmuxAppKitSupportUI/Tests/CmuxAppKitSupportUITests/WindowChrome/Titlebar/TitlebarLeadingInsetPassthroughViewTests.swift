import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct TitlebarLeadingInsetPassthroughViewTests {
    @Test func leadingInsetViewDoesNotParticipateInHitTesting() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        #expect(view.hitTest(NSPoint(x: 20, y: 10)) == nil)
    }

    @Test func leadingInsetViewCannotMoveWindowViaMouseDown() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        #expect(view.mouseDownCanMoveWindow == false)
    }
}
