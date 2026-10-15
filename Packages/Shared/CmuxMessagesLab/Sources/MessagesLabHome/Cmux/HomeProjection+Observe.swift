import CmuxHomeCore
import Observation

extension HomeProjection {
    /// One update per store change (Observation, no polling), as HomeStoreBinding does.
    func observe() {
        guard !stopped else { return }
        let id = conversation
        withObservationTracking {
            _ = homeStore.transcriptVersion[id, default: 0] // // crash program: a dictionary read the ratchet can type
            _ = homeStore.typing[id, default: []]
            _ = homeStore.drafts[id] // the agent's running reply grows its bubble
            _ = homeStore.liveRun(in: id) // a Chief's live run: its reply so far and activity line
            _ = homeStore.isConfirmed(id) // a send held for the owner goes once it names this conversation
            _ = homeStore.rows
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.refresh()
                self.observe()
            }
        }
    }
}
