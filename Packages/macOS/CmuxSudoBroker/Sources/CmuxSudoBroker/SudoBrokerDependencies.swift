struct SudoBrokerDependencies: Sendable {
    let clock: any SudoBrokerClock
    let pam: any SudoPAMChecking
    let runner: any SudoRunnerLaunching
    let recovery: any SudoInterruptedExecutionRecovering
    let watcher: (any SudoSpoolWatching)?
    let requesterInspector: any SudoProcessInspecting

    init(
        clock: any SudoBrokerClock,
        pam: any SudoPAMChecking,
        runner: any SudoRunnerLaunching,
        recovery: any SudoInterruptedExecutionRecovering,
        watcher: (any SudoSpoolWatching)?,
        requesterInspector: any SudoProcessInspecting
    ) {
        self.clock = clock
        self.pam = pam
        self.runner = runner
        self.recovery = recovery
        self.watcher = watcher
        self.requesterInspector = requesterInspector
    }
}
