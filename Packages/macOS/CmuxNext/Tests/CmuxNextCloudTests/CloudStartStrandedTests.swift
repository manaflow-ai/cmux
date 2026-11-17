@testable import CmuxNextCloud
import Foundation
import Testing

/// A Cloud start that can't go on after its machine was made for it deletes that machine; one whose Retry reuses the
/// machine keeps it, and a machine the start found is never deleted. Leo, 2026-11-10: "did you guys not test these".
@Suite @MainActor struct CloudStartStrandedTests {
    struct Boom: Error {}
    let made = CloudMoveCLI.StartChatPlan(createKey: "c", tabKey: "t")

    @Test func onlyAFailureWithAWorkingRetryKeepsTheMachine() {
        #expect(!CloudMoveCLI.StartChatPlan.strands(CloudMoveFailure(message: "stopped answering", retry: .move(machineID: "m1"))))
        #expect(CloudMoveCLI.StartChatPlan.strands(CloudMoveFailure(message: "too big to copy")))
        #expect(CloudMoveCLI.StartChatPlan.strands(Boom()))
        #expect(!CloudMoveCLI.StartChatPlan.strands(CancellationError()))
    }

    @Test func aMachineIsMadeForTheStartOnlyWhenTheAppOrThePlatformMadeItNow() {
        #expect(made.madeForStart)
        #expect(!CloudMoveCLI.StartChatPlan(machine: "vm-found", createKey: "c", tabKey: "t").madeForStart)
        #expect(CloudMoveCLI.StartChatPlan(machine: "vm-ensured", createKey: "c", tabKey: "t", madeForSend: true).madeForStart)
    }

    @Test func aStrandedStartDeletesItsMachineAndRethrows() async {
        var deleted = 0
        await #expect(throws: Boom.self) {
            try await made.releasing(sameAccount: { true }, delete: { deleted += 1 }) { () async throws -> String in throw Boom() }
        }
        #expect(deleted == 1)
        // A Retry that reuses the machine, another account, a found machine or a success: nothing is deleted.
        _ = try? await made.releasing(sameAccount: { true }, delete: { deleted += 1 }) { () async throws -> String in
            throw CloudMoveFailure(message: "x", retry: .move(machineID: "m1"))
        }
        _ = try? await made.releasing(sameAccount: { false }, delete: { deleted += 1 }) { () async throws -> String in throw Boom() }
        _ = try? await CloudMoveCLI.StartChatPlan(machine: "vm-found", createKey: "c", tabKey: "t").releasing(sameAccount: { true },
                                                    delete: { deleted += 1 }) { () async throws -> String in throw Boom() }
        #expect(try! await made.releasing(sameAccount: { true }, delete: { deleted += 1 }) { "ok" } == "ok")
        #expect(deleted == 1)
    }
}
