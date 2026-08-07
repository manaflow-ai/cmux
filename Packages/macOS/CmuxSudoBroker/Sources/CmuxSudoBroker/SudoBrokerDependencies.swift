struct SudoBrokerDependencies: Sendable {
    let clock: any SudoBrokerClock
    let pam: any SudoPAMChecking
    let runner: any SudoRunnerLaunching
    let recovery: any SudoInterruptedExecutionRecovering
    let watcher: (any SudoSpoolWatching)?
}
