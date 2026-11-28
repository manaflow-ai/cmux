import AppKit
import Foundation
import CmuxNextDesign
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

    /// infinite-tabs-flat: a released chat keeps a dormant record in memory and its frame in a file, not the frame's
    /// bytes (100 hidden chats held 50 to 200 MB of encoded pictures in the app). Its pane still gets it, once.
    @Test func aHeldFrameLeavesMemoryForAFileAndItsPaneStillGetsIt() async throws {
        let images = AgentPaneLaunchImages(directory: nil)
        #expect(await images.hold("tab_chat", try Self.frame(), size: NSSize(width: 4, height: 4), appearance: nil))
        await images.heldFramesSettled()
        let held = images.heldFrameCounts
        #expect(held.count == 1 && held.bytes > 0)
        #expect(held.memoryBytes == 0)  // written: only the record stays
        #expect(images.lastPage("tab_chat") != nil)
        let shown = try #require(images.take("tab_chat", size: NSSize(width: 4, height: 4)))
        #expect(shown.size == NSSize(width: 4, height: 4))
        #expect(images.take("tab_chat") == nil)  // handed out once
        await images.heldFramesSettled()
        #expect(images.heldFrameCounts.count == 0 && images.heldFrameCounts.bytes == 0)  // its file went with it
    }

    @Test func aHeldFrameInTheOtherLookIsNotTheLastPage() async throws {
        let images = AgentPaneLaunchImages(directory: nil)
        #expect(await images.hold("tab_chat", try Self.frame(), size: NSSize(width: 4, height: 4), appearance: .darkAqua))
        #expect(images.lastPage("tab_chat", appearance: .aqua) == nil)  // a dark page on a light card: the label instead
        #expect(images.lastPage("tab_chat", appearance: .darkAqua) != nil)
    }

    @Test func aReleasedChatWithNoViewStillShowsItsLastPageAndKeepsIt() async throws {
        let images = AgentPaneLaunchImages(directory: nil)
        #expect(await images.hold("tab_chat", try Self.frame(), size: NSSize(width: 4, height: 4), appearance: nil))
        var kept: [String: CGImage] = [:]
        // A released chat's view is gone (the app's lookup gives nil); its held frame is still its picture.
        let pictures = AgentPanePictures(view: { _ in nil }, images: images, keep: { kept[$0] = $1 })
        let picture = await pictures.picture("tab_chat", fit: CGSize(width: 640, height: 320)) { kept["tab_chat"] }
        #expect(picture != nil)
        #expect(kept["tab_chat"] != nil)  // the next hover reads it from the app's store
        #expect(await pictures.picture("tab_other", fit: CGSize(width: 640, height: 320)) { nil } == nil)
    }

    /// A chat's page is clear over its own ground: its hover picture is the page laid over that ground, so an empty
    /// chat's tile is the chat's color, never the flat white of a Chromium JPEG's clear pixels (2026-11-23 capture).
    @Test func aChatsCardPictureIsItsClearPageOverItsGround() throws {
        let clear = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let ground = ThemeRGB(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let flat = PageImageBackground.flattened(clear, over: ground)
        let pixel = NSBitmapImageRep(cgImage: flat).colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
        #expect(abs((pixel?.redComponent ?? 1) - 0.1) < 0.02 && (pixel?.alphaComponent ?? 0) == 1, "the clear page did not take the chat's ground")
        // A see-through window: no ground of its own, so the backdrop shows through the picture as through the page.
        #expect(PageImageBackground.flattened(clear, over: ThemeRGB(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.5)) === clear)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// #56159: a workspace switch hid the workspace before each pane's leave, so its chats were never pictured and
    /// the sidebar card's tile showed only the title. A workspace about to hide pictures the chats it shows, and only
    /// those (a chat in another workspace or window is left alone).
    @Test func aWorkspaceAboutToHidePicturesTheChatsItShows() throws {
        _ = NSApplication.shared
        let source = AgentPaneSource.bundled(URL(filePath: "/dev/null"))
        let inside = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: source))
        let elsewhere = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: source))
        let workspace = NSView(), other = NSView(), pane = NSView()
        workspace.addSubview(pane)
        pane.addSubview(inside)
        other.addSubview(elsewhere)
        let pictures = AgentPanePictures(view: { _ in nil }, keep: { _, _ in })
        let asked = pictures.willHide(workspace, chats: [("a", inside), ("b", elsewhere)])
        #expect(asked == ["a"], "the hiding workspace's chat was not pictured, or another one was")
    }
}
