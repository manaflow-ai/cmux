import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// #17601 on base's profile control (leoli-24, 2026-10-07): signed in, the
/// control draws the cmux user's picture, else their initials, in the
/// profile avatar's circle.
@MainActor @Suite struct SidebarAccountAvatarTests {
    static func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func initialsComeFromTheNameOrEmail() {
        #expect(SidebarAvatar.initials(for: "Leo Li") == "LL")
        #expect(SidebarAvatar.initials(for: "lawrence") == "L")
        #expect(SidebarAvatar.initials(for: "ada lovelace byron") == "AB")
        #expect(SidebarAvatar.initials(for: "ada@example.com") == "A")
        #expect(SidebarAvatar.initials(for: "  ") == "?")
    }

    @Test func anAccountAvatarCarriesItsInitialsAndPicture() throws {
        let data = try Self.png()
        let avatar = SidebarAvatar.account(name: "Leo Li", imageData: data)
        #expect(avatar.name == "Leo Li")
        #expect(avatar.initial == "LL")
        #expect(avatar.imageData == data)
        #expect(avatar.color == nil)
        #expect(SidebarAvatarView.picture(avatar) != nil, "the picture replaces the initials")
        #expect(SidebarAvatarView.picture(.account(name: "Leo Li")) == nil)
        #expect(SidebarAvatarView.picture(.account(name: "Leo Li", imageData: Data("nope".utf8))) == nil, "undecodable data draws the initials")
        #expect(SidebarAvatar(name: "Work").initial == "W", "a profile keeps its one initial")
    }
}
