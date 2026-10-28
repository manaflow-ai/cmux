import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing
import UniformTypeIdentifiers

/// Each Chief keeps its own picture (user, 2026-10-20: "changing profile pic of one chief should
/// not change it for all of them"): the Home list draws every Chief row with the avatar of that
/// row's own Chief, read from that Chief's own brain home, and clearing one Chief's picture puts
/// only that Chief back on the default.
@Suite struct PerChiefAvatarTests {
    static let lanes = BackgroundWork(label: "test.chief-avatars")

    static let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")

    /// The Home list's rows for one DM with each Chief in `chiefs` (id, name), built the way
    /// the app builds them (the mirror's public `inboxRows`).
    static func chiefRows(_ chiefs: [(String, String)]) -> [InboxRow] {
        let at = Date(timeIntervalSince1970: 1_000)
        let summaries = chiefs.map { chief, name in
            let participant = Participant(id: ParticipantID(chief), kind: .agent, displayName: name, agentClass: .chief)
            return ConversationSummary(id: ConversationID("conv_\(chief)"), title: name, participants: [me, participant],
                                       createdAt: at, updatedAt: at)
        }
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }

    static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-per-chief-avatar-\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func avatars(_ model: HomeSidebarModel) -> [String: HomeChiefAvatar?] {
        Dictionary(uniqueKeysWithValues: (model.pinned + model.rows).map { ($0.title, $0.chiefAvatar) })
    }

    @Test func eachChiefRowShowsItsOwnChiefsAvatar() {
        let rows = Self.chiefRows([("agent_mux", "Chief"), ("agent_scout01", "Scout")])
        #expect(rows.map(\.kind) == [.chief, .chief])
        let fallback = HomeChiefAvatar.text("🐱")
        let before = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me.id, chiefAvatars: [:], defaultChiefAvatar: fallback)
        #expect(Self.avatars(before) == ["Chief": fallback, "Scout": fallback])

        // Change only Chief A's picture: Chief B keeps the default.
        let after = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me.id,
                                     chiefAvatars: ["agent_mux": .text("A")], defaultChiefAvatar: fallback)
        #expect(Self.avatars(after) == ["Chief": .text("A"), "Scout": fallback])

        // Change only Chief B's: Chief A is not touched.
        let other = HomeSidebarModel(rows: rows, pins: HomePins(), me: Self.me.id,
                                     chiefAvatars: ["agent_mux": .text("A"), "agent_scout01": .text("B")],
                                     defaultChiefAvatar: fallback)
        #expect(Self.avatars(other) == ["Chief": .text("A"), "Scout": .text("B")])
    }

    @Test func eachChiefsAvatarIsReadFromItsOwnHomeAndSurvivesARelaunch() async throws {
        let home = try Self.home()
        let chiefs: Set<String> = ["agent_mux", "agent_scout01"]
        let scout = HomeChiefFiles(muxHome: ChiefHome.brainHome(muxHome: home, chief: "agent_scout01"))
        let mux = HomeChiefFiles(muxHome: ChiefHome.brainHome(muxHome: home, chief: nil))

        #expect(await HomeChiefAvatars(muxHome: home, files: Self.lanes).read(chiefs: chiefs).isEmpty)

        // Setting Scout's avatar changes Scout only.
        scout.writeAvatar("SC")
        #expect(await HomeChiefAvatars(muxHome: home, files: Self.lanes).read(chiefs: chiefs) == ["agent_scout01": .text("SC")])

        // Setting the default Chief's avatar leaves Scout's as it was.
        mux.writeAvatar("MX")
        // A new reader is a relaunch: the pictures come back from each Chief's own files.
        let relaunched = await HomeChiefAvatars(muxHome: home, files: Self.lanes).read(chiefs: chiefs)
        #expect(relaunched == ["agent_mux": .text("MX"), "agent_scout01": .text("SC")])

        // Clearing Scout's puts Scout alone back on the default.
        scout.clearPicture()
        #expect(await HomeChiefAvatars(muxHome: home, files: Self.lanes).read(chiefs: chiefs) == ["agent_mux": .text("MX")])
    }

    /// Two Chiefs' non-square pictures, both `avatar.png` and saved in the same second, must not
    /// share the squared tile copy (the cache was keyed by file name and time only).
    @Test func twoChiefsPicturesSavedInTheSameSecondKeepTheirOwnTile() throws {
        let home = try Self.home()
        var tiles: [URL] = []
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        for chief in ["agent_mux", "agent_scout01"] {
            let files = HomeChiefFiles(muxHome: ChiefHome.brainHome(muxHome: home, chief: chief == "agent_mux" ? nil : chief))
            let folder = files.profileFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let picture = folder.appendingPathComponent("avatar.png")
            try ChiefPictureFilesTests.picture(.png, width: 120, height: 60, to: picture)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: picture.path)
            files.writeAvatar("avatar.png")
            guard case .picture(let tile)? = files.tileAvatar() else {
                Issue.record("\(chief) shows no picture")
                return
            }
            tiles.append(tile)
        }
        #expect(tiles[0] != tiles[1], "two Chiefs share one squared tile: \(tiles)")
    }
}
