import CmuxNextPages
import CmuxNextRemoteFetch

/// Tracks lookup failures separately from the fetch guard's definitive address refusals.
actor AgentPaneSourceIconResolver: RemoteAddressResolving {
    private let base: any RemoteAddressResolving
    private(set) var failures = 0

    init(_ base: any RemoteAddressResolving) { self.base = base }

    func resolve(_ host: String) async throws -> [RemoteAddress] {
        do { return try await base.resolve(host) }
        catch {
            failures += 1
            throw error
        }
    }
}
