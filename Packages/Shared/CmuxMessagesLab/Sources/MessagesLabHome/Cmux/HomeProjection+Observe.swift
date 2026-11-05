import CmuxHomeCore
import Observation

extension HomeProjection {
    /// One update per store change (Observation, no polling), as HomeStoreBinding does.
    ///
    /// The composer never waits on the transcript (user, 2026-10-20: typing lagged with ~75 agents
    /// streaming): a change to another conversation costs one ``HomeProjectionInputs`` compare,
    /// and a pass that falls in a keystroke's display frame waits for the next frame (one pass
    /// then, with the whole current value: `refresh` reads it all, so nothing is lost).
    ///
    /// Whole messages (the default) draw no reply text while it streams: the view reads the
    /// replies' shape (``HomeRunShape``: who writes, the activity line and the thought headline),
    /// which a talk token does not change, so a token wakes no whole-message view (HOT PATH AUDIT
    /// area F, row H1: one O(transcript) pass per token in every open Home view before).
    // perf-hot: 0.1ms home-stream-token (each store change of the open conversation; no wake for a talk token)
    func observe() {
        guard !stopped else { return }
        let id = conversation
        let text = core.replies == .streaming
        withObservationTracking {
            _ = homeStore.transcriptVersion[id, default: 0] // // crash program: a dictionary read the ratchet can type
            _ = homeStore.typing[id, default: []]
            if text {
                _ = homeStore.streams(in: id) // the running replies grow their bubbles
                _ = homeStore.liveRun(in: id) // a Chief's live run: its reply so far and activity line
            } else {
                _ = homeStore.runShape(in: id) // who writes, the activity line and the thought headline
            }
            _ = homeStore.isConfirmed(id) // a send held for the owner goes once it names this conversation
            _ = homeStore.rows
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observedWakes += 1
                self.observedPass()
                self.observe()
            }
        }
    }

    /// The observed store changed: refresh when this conversation's inputs did, after a keystroke's frame.
    func observedPass() {
        guard !heldPass else { return } // the held pass reads the newest value
        let now = HomeProjectionInputs(homeStore, conversation, replies: core.replies)
        guard now != observedInputs else { return }
        if controller.inKeystrokeFrame {
            heldPass = true
            controller.nextFrame { [weak self] in
                guard let self, !self.stopped else { return }
                self.heldPass = false
                self.observedPass()
            }
            return
        }
        observedInputs = now
        refresh()
    }

    /// The inputs `start`'s first refresh read (the first observed change compares against them).
    func noteObservedInputs() {
        observedInputs = HomeProjectionInputs(homeStore, conversation, replies: core.replies)
    }
}
