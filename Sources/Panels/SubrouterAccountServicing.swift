/// Account operations used by the Subrouter pane.
protocol SubrouterAccountServicing: Sendable {
    func listAccounts() async throws -> [SubrouterAccount]
    func addLocalCodexAccount() async throws -> [SubrouterAccount]
}
