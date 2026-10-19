package import Observation

/// Owns Cloud’s policy gate and takes one consistent account/team snapshot for requests.
@MainActor @Observable
package final class CloudTeamSelection {
    private let auth: CloudAuth
    private let configuration: CloudConfiguration
    private var policyGeneration: UInt64 = 0
    package var policyDisabled = false {
        didSet { if policyDisabled != oldValue { policyGeneration &+= 1 } }
    }
    package init(auth: CloudAuth, configuration: CloudConfiguration) {
        self.auth = auth; self.configuration = configuration
    }
    package var canCall: Bool {
        if policyDisabled || (auth.managedTeamID != nil && auth.teamID == nil) { return false }
        if case .localOnly = configuration.backend, configuration.linkSource == .legacy { return false }
        return true
    }
    package func current() throws -> CloudTeamScope.Selection {
        guard canCall, auth.isSignedIn, !auth.activeTeam.isSwitching, let account = auth.user?.id else {
            throw CloudTeamScope.Failure.unavailable
        }
        return .init(account: account, stackTeam: auth.teamID, generation: auth.activeTeam.generation &+ policyGeneration)
    }
}
