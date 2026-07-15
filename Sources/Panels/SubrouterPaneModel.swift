import Observation

/// Main-actor state and mutations for one Subrouter pane.
@MainActor
@Observable
final class SubrouterPaneModel {
    private(set) var accounts: [SubrouterAccount] = []
    private(set) var isLoading = false
    private(set) var isAddingCodexAccount = false
    private(set) var failure: SubrouterPaneFailure?
    private(set) var didAddCodexAccount = false

    private let service: any SubrouterAccountServicing

    init(service: any SubrouterAccountServicing) {
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            accounts = try await service.listAccounts()
        } catch {
            failure = SubrouterPaneFailure(error: error)
        }
    }

    func addCodexAccount() async {
        guard !isAddingCodexAccount else { return }
        isAddingCodexAccount = true
        failure = nil
        didAddCodexAccount = false
        defer { isAddingCodexAccount = false }
        do {
            accounts = try await service.addLocalCodexAccount()
            didAddCodexAccount = true
        } catch {
            failure = SubrouterPaneFailure(error: error)
        }
    }
}
