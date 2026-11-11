@testable import CmuxNextCloud
import Foundation
import Testing

/// `cmux link start-chat preflight`'s answer, before any machine or lease is made for a Cloud start: a folder past
/// the copy's limits is refused with the repositories inside it, which the start card offers. Leo, 2026-11-10, on a
/// start from ~/Projects that made a machine and then failed its copy: "then there's this limit".
@Suite struct CloudStartChatPreflightTests {
    @Test func aTooBigFolderIsRefusedWithItsRepositories() throws {
        let answer: [String: Any] = [
            "ok": false, "error_code": "copy.too_large", "error": "~/Projects is too big to copy to a Cloud machine",
            "folder": "~/Projects", "bytes": 21_582_000_000, "files": 323_831, "repos_more": true,
            "repos": [["name": "cmux", "path": "/Users/me/Projects/cmux"], ["name": "bad", "path": "relative"], ["path": "/no/name"]],
        ]
        let refusal = try #require(CloudMoveCLI.StartChatPreflightRefusal(answer: answer))
        #expect(refusal.folder == "~/Projects")
        #expect(refusal.repos == [.init(name: "cmux", path: "/Users/me/Projects/cmux")])
        #expect(refusal.more && !refusal.machineMade)
        #expect(refusal.files == 323_831)
        let details = refusal.details
        #expect(details["folder"] as? String == "~/Projects")
        #expect((details["repos"] as? [[String: String]])?.first?["path"] == "/Users/me/Projects/cmux")
        #expect(details["more"] as? Bool == true && details["machineMade"] as? Bool == false)
        #expect(CloudMoveCLI.StartChatPreflightRefusal.replyCode == "cloud_folder_too_big")
    }

    @Test func aPassOrAnyOtherAnswerRefusesNothing() {
        #expect(CloudMoveCLI.StartChatPreflightRefusal(answer: ["ok": true]) == nil)
        #expect(CloudMoveCLI.StartChatPreflightRefusal(answer: ["ok": false, "error_code": "usage.invalid"]) == nil)
        #expect(CloudMoveCLI.StartChatPreflightRefusal(answer: [:]) == nil)
    }
}
