import CmuxNextDaemon

extension DaemonService {
    /// Sends `terminalDefaultColors` to the connected daemon (`set-default-colors`).
    ///
    /// One push runs at a time; a change while it runs makes it send again,
    /// reading the colors when it does, so a burst of theme changes ends on
    /// the latest one in order. Without a connection nothing is sent: the
    /// next connect pushes. A failure is logged only, since a stale reply
    /// color must never fail the change that caused it.
    func pushTerminalDefaultColors() {
        terminalColorsPending = true
        guard terminalColorsPush == nil else { return }
        terminalColorsPush = Task { [weak self] in
            while let self, terminalColorsPending {
                terminalColorsPending = false
                guard connection != nil, let colors = terminalDefaultColors else { break }
                await run("set-default-colors") {
                    try await $0.setDefaultColors(fg: colors.foreground, bg: colors.background, cursor: colors.cursor)
                }
            }
            self?.terminalColorsPush = nil
        }
    }
}
