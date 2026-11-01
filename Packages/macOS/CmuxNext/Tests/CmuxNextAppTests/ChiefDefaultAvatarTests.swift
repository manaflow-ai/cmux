@testable import CmuxNextApp
@testable import CmuxNextChiefPetWiring
import CmuxNextFloating
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
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
        #expect(HomeHostView.defaultTileAvatar(picture: nil) == .text("C"))
        let upload = URL(fileURLWithPath: "/tmp/upload.png")
        #expect(HomeHostView.defaultTileAvatar(picture: upload) == .picture(upload), "a worn upload still shows")
    }

    /// Leo 2026-11-01: "im not seeing chiefs with the selected avatar appearance". A Chief given a
    /// character (the popover, Settings > Chiefs, the config file) wears it in Home; one never given
    /// one keeps its monogram.
    @MainActor @Test func aPickedCharacterIsTheChiefsHomePicture() throws {
        let picks = ChiefMascotPicks(defaults: nil, defaultChief: HomeChiefAvatars.defaultChief)
        let picture = { (chief: String?, file: JSONValue?) in
            ChiefPetSettingsRows.chosenPicture(of: chief, picks: picks, uploads: nil, in: nil, file: file)
        }
        #expect(picture("agent_scout01", nil) == nil, "no pick: the monogram")
        picks.remember("fox", for: "agent_scout01")
        let fox = try #require(ChiefPetMascot.fox.avatarURL)
        #expect(picture("agent_scout01", nil) == fox)
        #expect(HomeHostView.defaultTileAvatar(picture: picture("agent_scout01", nil)) == .picture(fox))
        #expect(picture("agent_scout02", nil) == nil, "one Chief's pick never shows on another")
        // The default Chief's character is home.chiefPetMascot, picked only when the file sets it.
        #expect(picture(nil, .object([:])) == nil)
        let moon = try #require(ChiefPetMascot.moon.avatarURL)
        let file = JSONValue.object(["home": .object(["chiefPetMascot": .string("moon")])])
        #expect(picture(nil, file) == moon)
        #expect(picture(HomeChiefAvatars.defaultChief, file) == moon)
        #expect(picture(nil, .object(["home": .object(["chiefPetMascot": .string("not-a-pet")])])) == nil)
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
        #expect(HomeChiefAvatar.resolved(nil) == .text("C"))
        #expect(HomeChiefAvatar.resolved(.text("🐙")) == .text("🐙"))
        #expect(HomeChiefAvatar.chiefDefault.isMonogram, "C draws as a monogram")
    }
}
