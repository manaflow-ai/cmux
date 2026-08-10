import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite("Mobile pending attachment")
struct MobilePendingAttachmentTests {
    @Test("legacy construction fails without publishing an unreadable file URL")
    func legacyConstructionPropagatesWriteFailure() throws {
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-pending-blocked-\(UUID())")
        try Data("not a directory".utf8).write(to: blockedDirectory)
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        let id = UUID()
        let expectedOutput = blockedDirectory
            .appendingPathComponent("attachment-\(id.uuidString).png")

        let attachment = MobilePendingAttachment(
            id: id,
            data: Data([0x89, 0x50]),
            format: "png",
            temporaryDirectory: blockedDirectory
        )

        #expect(attachment == nil)
        #expect(!FileManager.default.fileExists(atPath: expectedOutput.path))
    }
}
