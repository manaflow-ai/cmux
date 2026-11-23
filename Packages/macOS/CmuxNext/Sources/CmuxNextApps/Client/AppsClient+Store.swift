/// The App Store's reads over the supervisor connection (the native store; the React page reads the
/// same ops through its page relay).
extension AppsClient {
    /// Runs one read-only App Store op (`apps.catalog.list`, `apps.catalog.get`, `apps.asset.get`, ...)
    /// with `args`; the reply as the owner wrote it. Refused at once while the supervisor is unreachable.
    public func storeRead(_ op: String, args: AppJSON = .object([:])) async throws(AppsClientError) -> AppJSON {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        do throws(AppsTransportError) {
            return try await transport.storeCall(op, args: args)
        } catch {
            throw .refused(error)
        }
    }
}
