import CmuxMobileSupport
import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite("Mobile pending attachment")
struct MobilePendingAttachmentTests {
    @Test("compatibility data preserves missing backing file failure")
    func compatibilityDataReturnsNilForMissingBackingFile() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-pending-missing-\(UUID()).bin")
        let staged = MobileStagedAttachment(
            kind: .file,
            fileName: "missing.bin",
            localFileURL: missingURL,
            byteCount: 1
        )
        let attachment = MobilePendingAttachment(staged)

        let bytes: Data? = attachment.data
        #expect(bytes == nil)
    }

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
