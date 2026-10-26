import CmuxNextDaemon

extension AppServices {
    /// Starts the local daemon (AppDelegate, once per launch). `terminalColors` is built here, its first reader,
    /// so every daemon holds the colors terminals are painted with before it connects: its first answers to
    /// OSC 10/11/12 queries match the screen, and each connect sends them again (`TerminalColorSync`).
    func startLocalDaemon(prestart: DaemonPrestart?) {
        terminalColors.apply()
        daemon.start(launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                     terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                     resolvesShellIntegration: environment.resolvesShellIntegration, prestart: prestart)
    }
}
