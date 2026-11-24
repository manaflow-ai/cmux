@testable import CmuxNextAgentPane
import CmuxNextSettings
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

    /// A merge outranks green checks, which outrank a turn's end: a bigger moment's sound is not held back by a smaller one's gap.
    @Test func biggerMomentsOutrank() {
        #expect(AgentPaneFinishSound.Kind.merged.rank > AgentPaneFinishSound.Kind.ci.rank)
        #expect(AgentPaneFinishSound.Kind.ci.rank > AgentPaneFinishSound.Kind.turn.rank)
    }

    /// `pane.lookSound {kind}`: the finish sound is off, so only the active look's sound pack plays.
    @Test func lookSoundDecodesAndIsServed() {
        #expect(AgentPaneRequest(body: ["method": "pane.lookSound", "params": ["kind": "ci"]]) == .lookSound(.ci))
        #expect(AgentPaneRequest(body: ["method": "pane.lookSound", "params": ["kind": "deploy"]]) == .unsupported("pane.lookSound"))
        #expect(AgentPageOps.methods["pane.lookSound"] == "pane.lookSound", "the page host refuses the op")
    }

    /// The look's sound wins when it has one; a look-only ask with no look sound plays nothing, and
    /// the built-in sounds are unchanged otherwise.
    @Test func theLooksSoundWinsAndLookOnlyNeedsOne() {
        let look = NotificationSoundChoice(name: "Hero", volume: 0.8, level: "look:ciGreen")
        #expect(AgentPaneFinishSound.pick(.ci, look: .play(look), lookOnly: true)?.name == "Hero")
        #expect(AgentPaneFinishSound.pick(.ci, look: .play(look), lookOnly: true)?.volume == 0.8)
        #expect(AgentPaneFinishSound.pick(.ci, look: .unset, lookOnly: true) == nil)
        #expect(AgentPaneFinishSound.pick(.ci, look: .unset, lookOnly: false)?.name == "Pop")
        #expect(AgentPaneFinishSound.pick(.ci, look: .unset, lookOnly: false)?.volume == AgentPaneFinishSound.volume)
        // A pack that mutes the moment ("none", quiet hours, volume 0) silences the built-in sound too.
        #expect(AgentPaneFinishSound.pick(.turn, look: .muted, lookOnly: false) == nil)
        #expect(AgentPaneFinishSound.pick(.ci, look: .muted, lookOnly: true) == nil)
        // sounds.when "whenInactive": a pack's sound is muted while cmux is active, kept while it is not.
        #expect(AgentPaneFinishSound.muted(.play(look), when: .whenInactive, workspaceMuted: false, viewed: false, appActive: true) == .muted)
        #expect(AgentPaneFinishSound.muted(.play(look), when: .whenInactive, workspaceMuted: false, viewed: false, appActive: false) == .play(look))
        #expect(AgentPaneFinishSound.muted(.unset, when: .whenInactive, workspaceMuted: false, viewed: false, appActive: true) == .unset)
        #expect(AgentPaneFinishSound.muted(.play(look), when: .unlessViewed, workspaceMuted: false, viewed: false, appActive: true) == .play(look))
        // "unlessViewed" (the default): not while the person looks at this chat.
        #expect(AgentPaneFinishSound.muted(.play(look), when: .unlessViewed, workspaceMuted: false, viewed: true, appActive: true) == .muted)
        #expect(AgentPaneFinishSound.muted(.play(look), when: .always, workspaceMuted: false, viewed: true, appActive: true) == .play(look))
        // A muted workspace mutes the pack under every timing; an unset moment stays the page's own sound.
        #expect(AgentPaneFinishSound.muted(.play(look), when: .always, workspaceMuted: true, viewed: false, appActive: false) == .muted)
        #expect(AgentPaneFinishSound.muted(.unset, when: .always, workspaceMuted: true, viewed: false, appActive: false) == .unset)
        #expect(AgentPaneFinishSound.lookEvent(.turn) == .finished)
        #expect(AgentPaneFinishSound.lookEvent(.ci) == .ciGreen)
        #expect(AgentPaneFinishSound.lookEvent(.merged) == nil)
    }
}
