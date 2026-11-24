import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Testing
@testable import CmuxNextAgentPane

/// SPLIT OPEN review (2026-11-10). The chat's ground (`AgentPaneGround`) is the bottom view of the chat, and its pane's
/// launch image (the chat's last frame after a relaunch, a moved New Tab page's frame) lies under the chat: an opaque
/// ground covered that picture, so a relaunch showed an empty ground until the live page painted. The ground stays out
/// while a picture of the chat stands in below, and paints again when the picture goes.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentPaneGroundUnderPictureTests {
    private typealias Kit = AgentPaneNewPaneGroundTests

    @Test(.timeLimit(.minutes(1)))
    func theGroundStaysOutWhileAPictureOfTheChatStandsInBelow() async throws {
        let (view, host, window, scope) = try await Kit().pane(Kit.Case(chromium: false, newTab: true),
                                                              ground: SurfaceBackground(color: Kit.chatGround, opacity: 1))
        defer { withExtendedLifetime(scope) {}; view.page?.close(); window.close() }
        view.standOverPicture()
        let under = try Kit.pixel(of: host, at: CGPoint(x: 200, y: 150))
        #expect(under == Kit.rgb(Kit.window), "the chat's ground paints \(under) over the picture that stands in below it")
        view.pictureBelowWent()
        let after = try Kit.pixel(of: host, at: CGPoint(x: 200, y: 150))
        #expect(after == Kit.rgb(Kit.chatGround), "the ground did not come back when the picture went: \(after)")
    }
}
