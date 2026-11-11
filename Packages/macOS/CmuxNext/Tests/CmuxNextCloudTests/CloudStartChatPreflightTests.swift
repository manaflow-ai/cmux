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
        #expect(refusal.more)
        #expect(refusal.files == 323_831)
        let details = refusal.details
        #expect(details["folder"] as? String == "~/Projects")
        #expect((details["repos"] as? [[String: String]])?.first?["path"] == "/Users/me/Projects/cmux")
        #expect(details["more"] as? Bool == true)
        #expect(CloudMoveCLI.StartChatPreflightRefusal.replyCode == "cloud_folder_too_big")
    }

    @Test func aPassOrAnyOtherAnswerRefusesNothing() {
        #expect(CloudMoveCLI.StartChatPreflightRefusal(answer: ["ok": true]) == nil)
        #expect(CloudMoveCLI.StartChatPreflightRefusal(answer: ["ok": false, "error_code": "usage.invalid"]) == nil)
        #expect(CloudMoveCLI.StartChatPreflightRefusal(answer: [:]) == nil)
    }
}

/// A Cloud start that can't go on after its machine was made for it deletes that machine; one whose Retry reuses the
/// machine keeps it, and a machine the start found is never deleted. Leo, 2026-11-10: "did you guys not test these".
@Suite @MainActor struct CloudStartStrandedTests {
    struct Boom: Error {}
    let made = CloudMoveCLI.StartChatPlan(createKey: "c", tabKey: "t")

    @Test func onlyAFailureWithAWorkingRetryKeepsTheMachine() {
        #expect(!CloudStartStranded.strands(CloudMoveFailure(message: "stopped answering", retry: .move(machineID: "m1"))))
        #expect(CloudStartStranded.strands(CloudMoveFailure(message: "too big to copy")))
        #expect(CloudStartStranded.strands(Boom()))
        #expect(!CloudStartStranded.strands(CancellationError()))
    }

    @Test func aMachineIsMadeForTheStartOnlyWhenTheAppOrThePlatformMadeItNow() {
        #expect(CloudStartStranded.madeForStart(made))
        #expect(!CloudStartStranded.madeForStart(.init(machine: "vm-found", createKey: "c", tabKey: "t")))
        #expect(CloudStartStranded.madeForStart(.init(machine: "vm-ensured", createKey: "c", tabKey: "t", madeForSend: true)))
    }

    @Test func aStrandedStartDeletesItsMachineAndRethrows() async {
        var deleted = 0
        await #expect(throws: Boom.self) {
            try await CloudStartStranded.releasing(made, sameAccount: { true }, delete: { deleted += 1 }) { () async throws -> String in throw Boom() }
        }
        #expect(deleted == 1)
        // A Retry that reuses the machine, another account, a found machine or a success: nothing is deleted.
        _ = try? await CloudStartStranded.releasing(made, sameAccount: { true }, delete: { deleted += 1 }) { () async throws -> String in
            throw CloudMoveFailure(message: "x", retry: .move(machineID: "m1"))
        }
        _ = try? await CloudStartStranded.releasing(made, sameAccount: { false }, delete: { deleted += 1 }) { () async throws -> String in throw Boom() }
        _ = try? await CloudStartStranded.releasing(.init(machine: "vm-found", createKey: "c", tabKey: "t"), sameAccount: { true },
                                                    delete: { deleted += 1 }) { () async throws -> String in throw Boom() }
        #expect(try! await CloudStartStranded.releasing(made, sameAccount: { true }, delete: { deleted += 1 }) { "ok" } == "ok")
        #expect(deleted == 1)
    }
}
