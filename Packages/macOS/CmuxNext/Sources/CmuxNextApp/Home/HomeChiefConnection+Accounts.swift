import CmuxNextAccounts
import CmuxNextHomeEngine

extension HomeChiefConnection {
    /// The Chief card's row for `provider` from the app's connection model (cmux issue 34263).
    @MainActor
    init(_ model: ChiefConnections, _ provider: ChiefConnections.Provider) {
        let state: State = switch model.state(provider) {
        case .signedOut: .signedOut
        case .unavailable: .unavailable
        case .notConnected: .notConnected
        case .pending: .pending
        case .connected(let account): .connected(account: account)
        case .needsReauth: .needsReauth
        }
        self.init(provider: Provider(rawValue: provider.rawValue) ?? .gmail, state: state,
                  canDisconnect: model.canDisconnect(provider), working: model.isWorking(provider))
    }
}
