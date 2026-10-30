import CmuxNextWakeups

extension DaemonStore {
    /// Starts `isInDropGrace` when a connection that was up ends and clears it when one is up
    /// again or `dropGrace` passed. Only a drop starts it: a first connect that has not
    /// succeeded yet is `.connecting` until the startup deadline (`DaemonService`).
    func noteConnectionState(from old: DaemonConnectionState) {
        switch (old, connectionState) {
        case (.connected, .connected):
            return
        case (_, .connected):
            endDropGrace()
        case (.connected, _):
            isInDropGrace = true
            let timer = DemandTimer(owner: "DaemonStore.dropGrace", clock: dropGraceClock)
            dropGraceTimer = timer
            timer.schedule(after: dropGrace) { @MainActor [weak self] in
                guard let self, self.dropGraceTimer === timer else { return }
                self.endDropGrace()
            }
        default:
            return
        }
    }

    private func endDropGrace() {
        dropGraceTimer?.cancel()
        dropGraceTimer = nil
        if isInDropGrace { isInDropGrace = false }
    }
}
