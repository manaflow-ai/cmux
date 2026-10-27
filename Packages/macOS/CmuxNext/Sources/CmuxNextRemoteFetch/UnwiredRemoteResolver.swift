import Foundation

/// The resolver of a fetcher made before the composition root wired the app's
/// (``SystemRemoteResolver``): every lookup fails, so nothing is fetched.
public nonisolated struct UnwiredRemoteResolver: RemoteAddressResolving {
    public init() {}

    public func resolve(_ host: String) async throws -> [RemoteAddress] {
        throw URLError(.cannotFindHost)
    }
}
