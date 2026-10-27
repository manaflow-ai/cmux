import CmuxHomeCore
import Observation

extension HomeProjection {
    /// One update per store change (Observation, no polling), as HomeStoreBinding does.
    ///
    /// The composer never waits on the transcript (user, 2026-10-20: typing lagged with ~75 agents
    /// streaming): a change to another conversation costs one ``HomeProjectionInputs`` compare,
    /// and a pass that falls in a keystroke's display frame waits for the next frame (one pass
    /// then, with the whole current value: `refresh` reads it all, so nothing is lost).
    func observe() {
        guard !stopped else { return }
        let id = conversation
        withObservationTracking {
            _ = homeStore.transcriptVersion[id, default: 0] // // crash program: a dictionary read the ratchet can type
            _ = homeStore.typing[id, default: []]
            _ = homeStore.streams(in: id) // the running replies grow their bubbles
            _ = homeStore.liveRun(in: id) // a Chief's live run: its reply so far and activity line
            _ = homeStore.isConfirmed(id) // a send held for the owner goes once it names this conversation
            _ = homeStore.rows
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observedPass()
                self.observe()
            }
        }
    }

    /// Mermaid fences map as text while the diagram engine is not loaded (HomeDiagramRowProvider.part);
    /// once it loads, a window that shows one maps again, so they become diagrams. Running replies map
    /// again with their next token.
    func observeDiagrams() {
        guard !stopped, let readiness = HomeDiagramRowProvider.installed?.readiness else { return }
        withObservationTracking {
            _ = readiness.loads
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if self.shown.contains(where: HomeProjection.mayHoldDiagram) { self.rebuild() }
                self.observeDiagrams()
            }
        }
    }

    /// Whether `item` has a text that may hold a Mermaid fence (a cheap test before a rebuild).
    static func mayHoldDiagram(_ item: TranscriptItem) -> Bool {
        item.parts.contains { part in
            if case .text(let text, _) = part { return text.range(of: "mermaid", options: .caseInsensitive) != nil }
            return false
        }
    }

    /// The observed store changed: refresh when this conversation's inputs did, after a keystroke's frame.
    func observedPass() {
        guard !heldPass else { return } // the held pass reads the newest value
        let now = HomeProjectionInputs(homeStore, conversation)
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
        observedInputs = HomeProjectionInputs(homeStore, conversation)
    }
}
