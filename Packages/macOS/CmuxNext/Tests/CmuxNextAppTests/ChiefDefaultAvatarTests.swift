@testable import CmuxNextApp
import CmuxNextFloating
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing

/// A Chief with no avatar of its own wears the chosen pet character (`home.chiefPetMascot`,
/// orb by default), never a plain disc. A Chief that sets its own avatar keeps it.
@Suite struct ChiefDefaultAvatarTests {
    static let lanes = BackgroundWork(label: "test.chief-avatars")

    static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-default-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aNewChiefsTileShowsThePetCharacter() throws {
        let files = HomeChiefFiles(muxHome: try Self.home())
        // A new Chief has no profile, so the tile falls back to the default.
        #expect(files.tileAvatar() == nil)
        let orb = try #require(ChiefPetMascot.orb.avatarURL)
        #expect(HomeHostView.defaultTileAvatar(mascot: nil) == .picture(orb))
        #expect(HomeHostView.defaultTileAvatar(mascot: "not-a-pet") == .picture(orb))
    }

    @Test func eachCharacterIsAnAvatar() throws {
        for mascot in ChiefPetMascot.allCases {
            let url = try #require(mascot.avatarURL, "\(mascot.rawValue) has an avatar picture")
            #expect(HomeHostView.defaultTileAvatar(mascot: mascot.rawValue) == .picture(url))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(HomeHostView.defaultTileAvatar(mascot: "fox") != HomeHostView.defaultTileAvatar(mascot: "orb"))
    }

    @Test func theHeaderWearsTheCharacterOnlyWithoutAnAvatar() async throws {
        let fox = try #require(ChiefPetMascot.fox.avatarURL)
        let bare = HomeChiefFiles(muxHome: try Self.home())
        let shown = await HomeChiefAvatars.headerAvatar(files: bare, fallback: fox, on: Self.lanes)
        #expect(shown.text == nil)
        #expect(shown.picture == (try Data(contentsOf: fox)))
        let own = HomeChiefFiles(muxHome: try Self.home())
        own.writeAvatar("AB")
        let kept = await HomeChiefAvatars.headerAvatar(files: own, fallback: fox, on: Self.lanes)
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

/// Without the character's picture, the header draws the Chief's own picture or text, else 🫡.
@Suite struct ChiefDefaultHeaderAvatarTests {
    @Test func theHeaderSalutesOnlyWithoutAnAvatar() {
        #expect(HomeChiefAvatar.headerText(nil, hasPicture: false) == "🫡")
        #expect(HomeChiefAvatar.headerText(nil, hasPicture: true) == nil)
        #expect(HomeChiefAvatar.headerText("AB", hasPicture: false) == "AB")
        #expect(HomeChiefAvatar.resolved(nil) == .text("🫡"))
        #expect(HomeChiefAvatar.resolved(.text("🐙")) == .text("🐙"))
        #expect(!HomeChiefAvatar.chiefDefault.isMonogram, "🫡 draws as an emoji, not a monogram")
    }
}
