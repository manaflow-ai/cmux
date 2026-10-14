import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowCaptureOutputNameTests {
    private let uuid = UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!

    @Test func identifiersSortByTimeAndCarryAUniqueSuffix() {
        let name = WindowCaptureOutputName(
            date: Date(timeIntervalSince1970: 1_790_000_000),
            uuid: uuid
        )

        #expect(name.identifier.hasSuffix("_1a2b3c4d"))
        #expect(!name.identifier.contains(":"))
    }

    @Test func aLabelBecomesTheFilenamePrefix() throws {
        let filename = try WindowRecordingRequest.make(params: [
            "label": "sidebar tour",
            "format": "gif",
        ]).outputFilename(WindowCaptureOutputName(identifier: "2026-09-28T07-14-03Z_1a2b3c4d"))

        #expect(filename == "sidebar-tour_2026-09-28T07-14-03Z_1a2b3c4d.gif")
    }

    @Test func noLabelLeavesJustTheIdentifier() throws {
        let filename = try WindowRecordingRequest.make(params: [
            "label": "   ",
            "format": "mp4",
        ]).outputFilename(WindowCaptureOutputName(identifier: "id"))

        #expect(filename == "id.mp4")
    }

    @Test func aPathSeparatorInALabelCannotEscapeTheDirectory() throws {
        let filename = try WindowRecordingRequest.make(params: [
            "label": "../../etc/passwd",
            "format": "mp4",
        ]).outputFilename(WindowCaptureOutputName(identifier: "id"))

        #expect(!filename.contains("/"))
        #expect(filename == "etc-passwd_id.mp4")
    }

    @Test func aStillIsNamedTheSameWayUnderTheScreenshotDirectory() throws {
        let filename = try WindowScreenshotRequest.make(params: [
            "label": "settings sheet",
            "format": "jpeg",
        ]).outputFilename(WindowCaptureOutputName(identifier: "2026-09-28T07-14-03Z_1a2b3c4d"))

        #expect(filename == "settings-sheet_2026-09-28T07-14-03Z_1a2b3c4d.jpg")
        // Stills keep the directory the DEBUG screenshot command has always
        // used, so anything already collecting cmux screenshots finds these.
        #expect(WindowScreenshotRequest.outputDirectoryName == "cmux-screenshots")
        #expect(WindowRecordingRequest.outputDirectoryName == "cmux-recordings")
    }
}
