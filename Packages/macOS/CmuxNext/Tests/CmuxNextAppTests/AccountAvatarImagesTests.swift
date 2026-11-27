import AppKit
@testable import CmuxNextApp
import CmuxNextSidebar
import Testing

/// Leo 2026-10-20 (sidebar-footer.png): the signed-in account's footer avatar showed the "L" initial
/// instead of the profile picture. Stack Auth stores an uploaded picture as a `data:image/...;base64,`
/// URL, which the HTTPS-only loader dropped; the picture now decodes in place and draws in the circle.
@MainActor struct AccountAvatarImagesTests {
    private static func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func anInlinePictureDecodesToItsBytes() throws {
        let png = try Self.png()
        let url = "data:image/png;base64,\(png.base64EncodedString())"
        let payload = try #require(AccountAvatarImages.inlineURL(url))
        #expect(AccountAvatarImages.decodeInline(payload) == png)
    }

    @Test func otherURLsAreNotInline() {
        #expect(AccountAvatarImages.inlineURL("https://avatars.githubusercontent.com/u/1") == nil)
        #expect(AccountAvatarImages.inlineURL("data:text/plain;base64,aGk=") == nil, "not an image")
        #expect(AccountAvatarImages.inlineURL("data:image/svg+xml,<svg/>") == nil, "not base64")
    }

    @Test func anInlinePayloadThatIsNoPictureDecodesToNothing() throws {
        let payload = try #require(AccountAvatarImages.inlineURL("data:image/png;base64,\(Data("not a png".utf8).base64EncodedString())"))
        #expect(AccountAvatarImages.decodeInline(payload) == nil)
    }

    @Test func theSignedInAccountDrawsItsLoadedPicture() async throws {
        let png = try Self.png()
        let url = "data:image/png;base64,\(png.base64EncodedString())"
        let images = AccountAvatarImages()
        images.load(url)
        for _ in 0..<50 where images.data[url] == nil { await Task.yield() }
        let bytes = try #require(images.data[url], "the inline picture loads")
        let account = try #require(SidebarAccount(name: nil, email: "leo@cmux.com", imageData: bytes))
        #expect(account.avatar.imageData == png, "the footer avatar draws the picture, not the initial")
        #expect(account.avatar.initial == "L", "the initial stays the fallback")
    }
}
