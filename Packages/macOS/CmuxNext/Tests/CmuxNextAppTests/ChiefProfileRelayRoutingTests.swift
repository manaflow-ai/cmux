@testable import CmuxNextHomeEngine
import CmuxNextDaemon
import Testing

/// The Chief editor's page relay routing (u2586, docs/chiefs-create-byo-backend.md): History and
/// Undo reach the Chief owner, Undo and the `locked` switch go only with the person's gesture, and
/// a name-only update still goes as the page.
@Suite struct ChiefProfileRelayRoutingTests {
    @Test func historyAndUndoAreRelayed() {
        #expect(ChiefProfilePageRelay.operations.contains("chief.profile.history"))
        #expect(ChiefProfilePageRelay.operations.contains("chief.profile.undo"))
    }

    @Test func undoAlwaysNeedsTheGesture() {
        #expect(ChiefProfilePageRelay.needsGesture("chief.profile.undo", params: ["chief": .string("agent_chief")]))
        #expect(ChiefProfilePageRelay.needsGesture("chief.profile.undo",
                                                   params: ["chief": .string("agent_chief"), "to_rev": .number(2)]))
        #expect(!ChiefProfilePageRelay.needsGesture("chief.profile.history", params: ["chief": .string("agent_chief")]))
    }

    @Test(arguments: ["locked", "harness", "model", "effort"])
    func backendAndLockAreGestureFields(_ field: String) {
        #expect(ChiefProfilePageRelay.needsGesture("chief.profile.update",
                                                   params: ["chief": .string("agent_chief"), field: .string("x")]))
    }

    @Test func aNameOnlyUpdateGoesAsThePage() {
        #expect(!ChiefProfilePageRelay.needsGesture("chief.profile.update",
                                                    params: ["chief": .string("agent_chief"), "display_name": .string("Ship")]))
    }
}
