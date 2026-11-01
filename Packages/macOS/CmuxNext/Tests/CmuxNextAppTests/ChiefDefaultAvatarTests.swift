@testable import CmuxNextApp
import CmuxNextFloating
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// A Chief with no avatar of its own wears its iMessage-style monogram (Lawrence 2026-10-30: "CH
/// for chief? like in imessage. no profile pic by default"), never the pet character. A Chief that
/// sets its own avatar, or wears an upload, keeps it.
@Suite struct ChiefDefaultAvatarTests {
    static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aNewChiefsTileIsItsMonogram() throws {
        let files = HomeChiefFiles(muxHome: try Self.home())
        // A new Chief has no profile, so the tile falls back to the default: the CH monogram.
        #expect(files.tileAvatar() == nil)
        #expect(HomeHostView.defaultTileAvatar(picture: nil) == .text("CH"))
        let upload = URL(fileURLWithPath: "/tmp/upload.png")
        #expect(HomeHostView.defaultTileAvatar(picture: upload) == .picture(upload), "a worn upload still shows")
    }

    @Test func eachCharacterStillHasAPetPicture() throws {
        for mascot in ChiefPetMascot.allCases {
            let url = try #require(mascot.avatarURL, "\(mascot.rawValue) has an avatar picture")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func theHeaderHasNoPictureWithoutAnAvatar() async throws {
        let bare = HomeChiefFiles(muxHome: try Self.home())
        let shown = await HomeChiefAvatars.headerAvatar(files: bare, fallback: nil)
        #expect(shown.text == nil)
        #expect(shown.picture == nil)
        let own = HomeChiefFiles(muxHome: try Self.home())
        own.writeAvatar("AB")
        let kept = await HomeChiefAvatars.headerAvatar(files: own, fallback: nil)
        #expect(kept.text == "AB")
        #expect(kept.picture == nil)
    }

    @Test func aChiefsOwnAvatarIsNotReplaced() throws {
        let files = HomeChiefFiles(muxHome: try Self.home())
        files.writeAvatar("AB")
        #expect(files.tileAvatar() == .text("AB"))
        #expect(files.headerAvatar().text == "AB")
        // Another Chief with no profile still has none of its own.
        #expect(HomeChiefFiles(muxHome: try Self.home()).tileAvatar() == nil)
    }
}

/// A Chief with no avatar of its own draws its monogram: the default Chief's is CH.
@Suite struct ChiefDefaultHeaderAvatarTests {
    @Test func theDefaultChiefIsCH() {
        #expect(HomeChiefAvatar.resolved(nil) == .text("CH"))
        #expect(HomeChiefAvatar.resolved(.text("🐙")) == .text("🐙"))
        #expect(HomeChiefAvatar.chiefDefault.isMonogram, "CH draws as a monogram")
    }
}
