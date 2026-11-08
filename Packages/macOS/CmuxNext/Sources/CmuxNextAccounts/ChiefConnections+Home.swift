public import CmuxNextHomeEngine

public extension HomeChiefConnection {
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

public extension HomeChiefConnectionsSection.Source {
    /// The Chief card's Google connections from the app's model (cmux issue 34263): its rows, a
    /// re-read when the card opens, and Connect or Disconnect.
    @MainActor
    init(_ connections: ChiefConnections) {
        self.init(
            rows: { [connections] in
                (ChiefConnections.Provider.allCases.map { HomeChiefConnection(connections, $0) }, connections.failed)
            },
            refresh: { [connections] in
                // task-owner: one list read per card open; the model drops an answer for a changed account
                Task { await connections.refresh() }
            },
            act: { [connections] provider, connect in
                guard let provider = ChiefConnections.Provider(rawValue: provider.rawValue) else { return }
                // task-owner: one Connect or Disconnect gesture; the model refuses a second while it runs
                Task { connect ? await connections.connect(provider) : await connections.disconnect(provider) }
            })
    }
}
