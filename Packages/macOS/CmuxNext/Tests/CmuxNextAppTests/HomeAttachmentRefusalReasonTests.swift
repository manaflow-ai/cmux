import CmuxHomeCore
import Foundation
@testable import CmuxNextHome
import Testing

/// Audit row 10 (unimpl-audit-ui.md): a send with attachments to an owner that stores no files
/// showed "Not Delivered" with a reason that either said "yet" or, for a cmux daemon too old for
/// attachments (`attachments_unsupported`), the generic "A message couldn't be sent." Each owner
/// that cannot take files (cmux Cloud, an older cmux, any owner with no file storage) says why and
/// what to do, both where the row fails at once (`notDeliveredReason`) and where a background
/// resend is refused (`rejection`). The router names a Cloud owner's refusal
/// (`cloud_attachments_unsupported`).
struct HomeAttachmentRefusalReasonTests {
    @Test func aLargeOriginalPassesComposerAdmission() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 100_000_001)
        try file.close()
        #expect(HomeComposerCheck.problem(for: .file(url)) == nil)
    }

    private let generic = HomeStrings.rejection(.invalid("something else"))

    @Test(arguments: ["attachments unsupported", "attachments_unsupported", "cloud_attachments_unsupported"])
    func anOwnerThatStoresNoFilesSaysWhyNotTheGenericRefusal(_ reason: String) {
        #expect(HomeStrings.notDeliveredReason(.invalid(reason)) != generic)
        #expect(HomeStrings.rejection(.invalid(reason)) != generic, "a background resend's refusal says why too")
    }

    @Test func cloudAnOlderCmuxAndAnOwnerWithNoStorageGiveDifferentReasons() {
        let reasons = ["cloud_attachments_unsupported", "attachments_unsupported", "attachments unsupported"]
            .map { HomeStrings.notDeliveredReason(.invalid($0)) }
        #expect(Set(reasons).count == 3)
        #expect(reasons.allSatisfy { !$0.contains("yet") }, "the reason names the cause, not a vague later")
    }

    @Test func otherRefusalsKeepTheirText() {
        #expect(HomeStrings.notDeliveredReason(.notAuthorized) == HomeStrings.rejection(.notAuthorized))
        #expect(HomeStrings.notDeliveredReason(.invalid("too_long")) == generic)
    }
}
