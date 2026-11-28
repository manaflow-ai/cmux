@testable import CmuxNextApp
@testable import CmuxNextChiefPetWiring
import CmuxNextFloating
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
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
        #expect(HomeHostView.defaultTileAvatar(picture: nil) == .text("CH"))
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
        #expect(HomeChiefAvatar.resolved(nil) == .text("CH"))
        #expect(HomeChiefAvatar.resolved(.text("🐙")) == .text("🐙"))
        #expect(HomeChiefAvatar.chiefDefault.isMonogram, "CH draws as a monogram")
    }

    /// A settings file of ~157 KB (Leo's) once went to Rust whole on every `picked` call, which the
    /// sidebar makes per Chief per row: 2-6 s on the main thread with ~1,100 workspaces. Only
    /// `home.chiefPetMascot` goes now; the answer is the same, and 1,100 calls stay well under a frame each.
    @MainActor @Test func pickedSendsOnlyTheMascotNotTheWholeFile() throws {
        let picks = ChiefMascotPicks(defaults: nil, defaultChief: HomeChiefAvatars.defaultChief)
        picks.remember("fox", for: "agent_scout01")
        var root: [String: JSONValue] = [:]
        for n in 0..<1_100 { root["workspace\(n)"] = .object(["title": .string(String(repeating: "x", count: 120))]) }
        root["home"] = .object(["chiefPetMascot": .string("moon"), "other": .string("kept out")])
        let file = JSONValue.object(root)
        let clock = ContinuousClock()
        var answers: [String?] = []
        let elapsed = clock.measure {
            for _ in 0..<1_100 { answers.append(picks.picked(nil, in: file)); answers.append(picks.picked("agent_scout01", in: file)) }
        }
        print("Duress: 2,200 picked calls over a \(root.count)-key settings file: \(elapsed)")
        #expect(answers.allSatisfy { $0 == "moon" || $0 == "fox" })
        #expect(picks.picked(nil, in: file) == "moon")
        #expect(picks.picked("agent_scout01", in: file) == "fox")
        #expect(elapsed < .seconds(1), "per-row calls must not encode the whole file")
    }
}
