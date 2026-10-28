@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// The daemon's Chief registry is the one source of truth for a Chief's picture: a picture set
/// with the `profile` or `chiefs` tool (`chief.profile.avatar.set`) shows in the Home list, the
/// app's Choose Picture… and Use Default Picture write through the registry, and a picture still
/// named in a Chief's `optchat/profile.json` moves to the registry once, with a backup.
@Suite struct ChiefAvatarRegistryTests {
    static let lanes = BackgroundWork(label: "test.chief-avatars")

    /// The daemon's avatar store as the tools and the app see it.
    actor FakeRegistry: ChiefAvatarRegistry {
        var pictures: [String: ChiefAvatarPicture] = [:]
        var sets = 0
        var reachable = true

        func unreachable() { reachable = false }

        func pictureRefs() async throws -> [String: String] {
            guard reachable else { throw CocoaError(.fileReadUnknown) }
            return pictures.mapValues(\.sha256)
        }

        func picture(of chief: String) async throws -> ChiefAvatarPicture? {
            guard reachable else { throw CocoaError(.fileReadUnknown) }
            return pictures[chief]
        }

        func setPicture(_ picture: ChiefAvatarPicture, of chief: String) async throws {
            guard reachable else { throw CocoaError(.fileWriteUnknown) }
            sets += 1
            pictures[chief] = picture
        }

        func clearPicture(of chief: String) async throws {
            guard reachable else { throw CocoaError(.fileWriteUnknown) }
            pictures[chief] = nil
        }
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-avatar-registry-\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A square PNG's bytes.
    static func png(side: Int = 64) throws -> Data {
        let url = try folder().appendingPathComponent("p.png")
        try ChiefPictureFilesTests.picture(.png, width: side, height: side, to: url)
        return try Data(contentsOf: url)
    }

    static func files(_ home: URL, _ chief: String) -> HomeChiefFiles {
        HomeChiefFiles(muxHome: ChiefHome.brainHome(muxHome: home, chief: chief == "agent_mux" ? nil : chief))
    }

    @Test func aPictureSetWithAToolShowsInTheHomeList() async throws {
        let home = try Self.folder(), cache = try Self.folder()
        let registry = FakeRegistry()
        let bytes = try Self.png()
        // What `profile` / `chiefs` with avatar_path does: chief.profile.avatar.set on the daemon.
        try await registry.setPicture(ChiefAvatarPicture(mediaType: "image/png", data: bytes), of: "agent_scout01")

        let avatars = HomeChiefAvatars(muxHome: home, registry: registry, cache: cache, files: Self.lanes)
        let shown = await avatars.read(chiefs: ["agent_mux", "agent_scout01"])
        guard case .picture(let url)? = shown["agent_scout01"] else {
            Issue.record("the tool's picture does not show: \(shown)")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(shown["agent_mux"] == nil, "another Chief took Scout's picture")
    }

    @Test func choosePictureAndUseDefaultWriteThroughTheRegistry() async throws {
        let home = try Self.folder(), cache = try Self.folder(), source = try Self.folder()
        let registry = FakeRegistry()
        let avatars = HomeChiefAvatars(muxHome: home, registry: registry, cache: cache, files: Self.lanes)
        let photo = source.appendingPathComponent("photo.jpg")
        try ChiefPictureFilesTests.picture(.jpeg, width: 3000, height: 2000, to: photo)

        try await avatars.setPicture(from: photo, chief: "agent_scout01")
        let stored = try #require(await registry.pictures["agent_scout01"])
        #expect(stored.mediaType == "image/png")
        let drawn = try #require(CGImageSourceCreateWithData(stored.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(max(drawn.width, drawn.height) == 512)
        #expect(Self.files(home, "agent_scout01").avatar() == nil, "the picture was also kept in profile.json")
        guard case .picture? = await avatars.read(chiefs: ["agent_scout01"])["agent_scout01"] else {
            Issue.record("the chosen picture does not show")
            return
        }

        try await avatars.clearPicture(chief: "agent_scout01")
        #expect(await registry.pictures["agent_scout01"] == nil)
        #expect(await avatars.read(chiefs: ["agent_scout01"]).isEmpty, "Use Default Picture left a picture")
    }

    @Test func aProfilePictureMovesToTheRegistryOnceWithABackup() async throws {
        let home = try Self.folder(), cache = try Self.folder()
        let registry = FakeRegistry()
        let files = Self.files(home, "agent_mux")
        let folder = files.profileFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = try Self.png()
        try bytes.write(to: folder.appendingPathComponent("avatar.png"))
        files.writeAvatar("avatar.png")

        let avatars = HomeChiefAvatars(muxHome: home, registry: registry, cache: cache, files: Self.lanes)
        guard case .picture(let url)? = await avatars.read(chiefs: ["agent_mux"])["agent_mux"] else {
            Issue.record("the old picture does not show")
            return
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(await registry.pictures["agent_mux"]?.data == bytes, "the picture did not move to the daemon")
        #expect(files.avatar() == nil, "profile.json still names the picture")
        let backup = folder.appendingPathComponent(HomeChiefAvatars.backupFolder)
        #expect(try Data(contentsOf: backup.appendingPathComponent("avatar.png")) == bytes)
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("profile.json").path))

        _ = await avatars.read(chiefs: ["agent_mux"])
        #expect(await registry.sets == 1, "the picture moved more than once")
    }

    @Test func aTextAvatarStaysInProfileJSON() async throws {
        let home = try Self.folder(), cache = try Self.folder()
        Self.files(home, "agent_scout01").writeAvatar("SC")
        let avatars = HomeChiefAvatars(muxHome: home, registry: FakeRegistry(), cache: cache, files: Self.lanes)
        #expect(await avatars.read(chiefs: ["agent_scout01"]) == ["agent_scout01": .text("SC")])
    }

    @Test func anUnreachableDaemonKeepsTheOldPictureAndMovesNothing() async throws {
        let home = try Self.folder(), cache = try Self.folder()
        let registry = FakeRegistry()
        await registry.unreachable()
        let files = Self.files(home, "agent_mux")
        let folder = files.profileFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.png().write(to: folder.appendingPathComponent("avatar.png"))
        files.writeAvatar("avatar.png")

        let avatars = HomeChiefAvatars(muxHome: home, registry: registry, cache: cache, files: Self.lanes)
        guard case .picture? = await avatars.read(chiefs: ["agent_mux"])["agent_mux"] else {
            Issue.record("the old picture went away while the daemon was down")
            return
        }
        #expect(files.avatar() == "avatar.png")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(HomeChiefAvatars.backupFolder).path))
    }
}
