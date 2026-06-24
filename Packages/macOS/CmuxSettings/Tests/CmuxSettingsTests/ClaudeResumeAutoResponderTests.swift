import Foundation
import Testing
@testable import CmuxSettings

@Suite("ClaudeResumeAutoResponder")
struct ClaudeResumeAutoResponderTests {
    private let menu = """
    ❯ 1. Resume from summary (recommended)
      2. Resume full session as-is
      3. Don't ask me again
    """

    @Test func firesExactlyOnce() {
        let responder = ClaudeResumeAutoResponder(mode: .full)
        #expect(responder.hasResponded == false)
        #expect(responder.evaluate(screen: menu) == [.down, .enter])
        #expect(responder.hasResponded == false)
        responder.confirmDelivered()
        #expect(responder.hasResponded == true)
        // Subsequent polls (menu still on screen) must not re-send.
        #expect(responder.evaluate(screen: menu) == nil)
    }

    @Test func doesNotDisarmUntilDeliveryIsConfirmed() {
        let responder = ClaudeResumeAutoResponder(mode: .full)
        #expect(responder.evaluate(screen: menu) == [.down, .enter])
        #expect(responder.evaluate(screen: menu) == [.down, .enter])
        responder.confirmDelivered()
        #expect(responder.evaluate(screen: menu) == nil)
    }

    @Test func waitsForMenuBeforeFiring() {
        let responder = ClaudeResumeAutoResponder(mode: .full)
        #expect(responder.evaluate(screen: "claude is starting up…") == nil)
        #expect(responder.hasResponded == false)
        #expect(responder.evaluate(screen: menu) == [.down, .enter])
        responder.confirmDelivered()
        #expect(responder.hasResponded == true)
    }

    @Test func askModeIsAlwaysInert() {
        let responder = ClaudeResumeAutoResponder(mode: .ask)
        #expect(responder.evaluate(screen: menu) == nil)
        #expect(responder.hasResponded == false)
    }
}
