/// Persistence isolated to the new v2 namespace, never Stack authentication.
public protocol V2StateStoring: Sendable {
    /// Reads this exact identity's current cache if it exists.
    /// - Parameter identity: Every authorization and build scope component.
    /// - Returns: A matching v2 record, or nil for first enrollment.
    /// - Throws: An I/O or scope error; callers must not recover by importing legacy state.
    func load(identity: V2Identity) async throws -> V2CachedState?
    /// Replaces this identity's single cache atomically.
    /// - Parameter state: The complete latest state, without token history.
    /// - Throws: An I/O error if the write fails.
    func save(_ state: V2CachedState) async throws
}
