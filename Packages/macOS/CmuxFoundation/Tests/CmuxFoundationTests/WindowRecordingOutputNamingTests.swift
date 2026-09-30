import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingOutputNamingTests {
    private let uuid = UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!

    @Test func identifiersSortByTimeAndCarryAUniqueSuffix() {
        let identifier = WindowRecordingRequest.recordingIdentifier(
            date: Date(timeIntervalSince1970: 1_790_000_000),
            uuid: uuid
        )

        #expect(identifier.hasSuffix("_1a2b3c4d"))
        #expect(!identifier.contains(":"))
    }

    @Test func aLabelBecomesTheFilenamePrefix() throws {
        let filename = try WindowRecordingRequest.make(params: [
            "label": "sidebar tour",
            "format": "gif",
        ]).outputFilename(identifier: "2026-09-28T07-14-03Z_1a2b3c4d")

        #expect(filename == "sidebar-tour_2026-09-28T07-14-03Z_1a2b3c4d.gif")
    }

    @Test func noLabelLeavesJustTheIdentifier() throws {
        let filename = try WindowRecordingRequest.make(params: [
            "label": "   ",
            "format": "mp4",
        ]).outputFilename(identifier: "id")

        #expect(filename == "id.mp4")
    }

    @Test func aPathSeparatorInALabelCannotEscapeTheDirectory() throws {
        let filename = try WindowRecordingRequest.make(params: [
            "label": "../../etc/passwd",
            "format": "mp4",
        ]).outputFilename(identifier: "id")

        #expect(!filename.contains("/"))
        #expect(filename == "etc-passwd_id.mp4")
    }
}
