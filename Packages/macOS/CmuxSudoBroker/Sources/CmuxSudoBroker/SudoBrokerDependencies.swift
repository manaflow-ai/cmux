import Foundation

protocol SudoBrokerClock: Sendable {
    func now() async -> Date
}

protocol SudoPAMChecking: Sendable {
    func touchIDIsEnabled() -> Bool
}

extension SudoPAMConfiguration: SudoPAMChecking {}

struct SudoLaunchedRunner: Sendable, Equatable {
    let identity: SudoProcessIdentity
}

protocol SudoRunnerLaunching: Sendable {
    func launch(requestID: String, paths: SudoBrokerPaths) async throws -> SudoLaunchedRunner
}

protocol SudoInterruptedExecutionRecovering: Sendable {
    func recover(state: SudoRequestState, approvedDirectory: URL) async
}

struct SudoBrokerDependencies: Sendable {
    let clock: any SudoBrokerClock
    let pam: any SudoPAMChecking
    let runner: any SudoRunnerLaunching
    let recovery: any SudoInterruptedExecutionRecovering
}

