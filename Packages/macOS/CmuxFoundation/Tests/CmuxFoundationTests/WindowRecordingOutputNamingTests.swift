import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingOutputNamingTests {
    private let uuid = UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!

    @Test func identifiersSortByTimeAndCarryAUniqueSuffix() {
        let identifier = WindowRecordingOutputNaming.identifier(
            date: Date(timeIntervalSince1970: 1_790_000_000),
            uuid: uuid
        )

        #expect(identifier.hasSuffix("_1a2b3c4d"))
        #expect(!identifier.contains(":"))
    }

    @Test func aLabelBecomesTheFilenamePrefix() {
        let filename = WindowRecordingOutputNaming.filename(
            label: "sidebar tour",
            identifier: "2026-09-28T07-14-03Z_1a2b3c4d",
            format: .gif
        )

        #expect(filename == "sidebar-tour_2026-09-28T07-14-03Z_1a2b3c4d.gif")
    }

    @Test func noLabelLeavesJustTheIdentifier() {
        let filename = WindowRecordingOutputNaming.filename(
            label: "   ",
            identifier: "id",
            format: .mp4
        )

        #expect(filename == "id.mp4")
    }

    @Test func aPathSeparatorInALabelCannotEscapeTheDirectory() {
        let filename = WindowRecordingOutputNaming.filename(
            label: "../../etc/passwd",
            identifier: "id",
            format: .mp4
        )

        #expect(!filename.contains("/"))
        #expect(filename == "etc-passwd_id.mp4")
    }
}
