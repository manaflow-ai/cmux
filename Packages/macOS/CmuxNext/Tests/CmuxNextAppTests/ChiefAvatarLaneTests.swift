@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing

/// Chief avatar files are read on the BackgroundWork files lane passed in, never in a detached task on the
/// cooperative pool: with that lane shut down the read finds nothing, though the file is there.
@Suite struct ChiefAvatarLaneTests {
    static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-avatar-lane-\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func avatarReadsRunOnTheGivenFilesLane() async throws {
        let home = try Self.home()
        HomeChiefFiles(muxHome: ChiefHome.brainHome(muxHome: home, chief: "agent_scout01")).writeAvatar("SC")
        let work = BackgroundWork(label: "test.chief-avatars")
        #expect(await HomeChiefAvatars(muxHome: home, work: work).read(chiefs: ["agent_scout01"]) == ["agent_scout01": .text("SC")])
        // Lanes that take no more work: a read that went through them returns nothing.
        await work.shutdown()
        #expect(await HomeChiefAvatars(muxHome: home, work: work).read(chiefs: ["agent_scout01"]).isEmpty)
        let header = await HomeChiefAvatars.headerAvatar(files: HomeChiefFiles(muxHome: ChiefHome.brainHome(muxHome: home, chief: "agent_scout01")),
                                                         fallback: nil, work: work)
        #expect(header.text == nil && header.picture == nil)
    }
}
