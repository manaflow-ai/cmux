@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The page's finish sound (`pane.finishSound {kind}`): each kind decodes, anything else is
/// refused, the op is served on the page host, and sounds are at least 1.5 s apart.
@MainActor @Suite struct AgentPaneFinishSoundTests {
    @Test func eachKindDecodes() {
        for (name, kind) in [("turn", AgentPaneFinishSound.Kind.turn), ("ci", .ci), ("merged", .merged)] {
            #expect(AgentPaneRequest(body: ["method": "pane.finishSound", "params": ["kind": name]]) == .finishSound(kind))
        }
        for bad: [String: Any] in [[:], ["kind": ""], ["kind": "deploy"], ["kind": 1]] {
            #expect(AgentPaneRequest(body: ["method": "pane.finishSound", "params": bad]) == .unsupported("pane.finishSound"), "\(bad) decoded")
        }
        #expect(AgentPageOps.methods["pane.finishSound"] == "pane.finishSound", "the page host refuses the op")
    }

    @Test func soundsAreRateLimited() {
        #expect(AgentPaneFinishSound.admits(now: 10, last: nil))
        #expect(!AgentPaneFinishSound.admits(now: 11, last: 10))
        #expect(AgentPaneFinishSound.admits(now: 11.5, last: 10))
    }
}
