import AppKit
import Testing
@testable import CmuxNextAgentPane

/// #51768: a chat not on screen since launch cannot be pictured (Chromium pictures no hidden page), so the hover
/// card's split miniature shows its last page: a released chat's held frame. Reading it never hands it out, so the
/// chat's own first frame still gets it.
@MainActor
struct AgentPaneLastPageTests {
    private static func frame() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    @Test func aHiddenChatsHeldFrameIsItsLastPageAndStaysForItsPane() async throws {
        let images = AgentPaneLaunchImages(directory: nil)
        #expect(images.lastPage("tab_chat") == nil)  // nothing held: the tile says the chat's title instead
        #expect(await images.hold("tab_chat", try Self.frame(), size: NSSize(width: 4, height: 4), appearance: nil))
        let page = try #require(images.lastPage("tab_chat"))
        #expect((page.width, page.height) == (8, 8))
        #expect(images.lastPage("tab_chat") != nil)  // read twice: a hover never takes it
        #expect(images.take("tab_chat") != nil)  // the pane's own first frame still gets it
        images.drop("tab_chat")
        #expect(images.lastPage("tab_chat") == nil)
    }
}
