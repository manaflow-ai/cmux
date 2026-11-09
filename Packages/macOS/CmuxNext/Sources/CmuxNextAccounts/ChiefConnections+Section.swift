public import CmuxNextHomeEngine

extension HomeChiefConnection {
    /// The Chief card's row for `provider` from the app's connection model (cmux issue 34263).
    @MainActor
    public init(_ model: ChiefConnections, _ provider: ChiefConnections.Provider) {
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

extension ChiefConnections {
    /// The Chief card's Connections section over this model: its rows, a list read when the card
    /// opens, and each Connect or Disconnect gesture.
    public var section: HomeChiefConnectionsSection.Source {
        .init(
            rows: { [self] in (Provider.allCases.map { HomeChiefConnection(self, $0) }, failed) },
            refresh: { [self] in
                // task-owner: one list read per card open; the model drops an answer for a changed account
                Task { await refresh() }
            },
            act: { [self] provider, connect in
                guard let provider = Provider(rawValue: provider.rawValue) else { return }
                // task-owner: one Connect or Disconnect gesture; the model refuses a second while it runs
                Task { connect ? await self.connect(provider) : await disconnect(provider) }
            })
    }
}
