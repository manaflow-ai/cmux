import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A preset approval card's Approve (acpmux `hub/unattended_presets.rs`) lets agents start chats
/// with no prompts from then on, so it goes only on the person's fresh click: typing in the pane,
/// or no gesture at all, never sends it (review F1 of #39333).
@MainActor struct AgentPanePresetApprovalGestureTests {
    @Test func approvingAPresetNeedsAFreshClickNotTyping() {
        let gestures = AgentPaneUserGestures()
        #expect(!AcpmuxPaneMethods.answerAllowed("_acpmux/presets", gestures), "no gesture")
        gestures.record()
        #expect(!AcpmuxPaneMethods.answerAllowed("_acpmux/presets", gestures), "typing approved a preset")
        gestures.record(click: true)
        #expect(AcpmuxPaneMethods.answerAllowed("_acpmux/presets", gestures), "the person's click")
    }

    @Test func thePaneSendsOnlyTheApprovalFields() {
        let known = AcpmuxPaneMethods.knownParams["_acpmux/presets"]
        #expect(known?.params == ["name", "approveMode", "approveDigest", "sessionId"])
        #expect(AcpmuxPaneMethods.sessionScoped.contains("_acpmux/presets"))
    }
}
