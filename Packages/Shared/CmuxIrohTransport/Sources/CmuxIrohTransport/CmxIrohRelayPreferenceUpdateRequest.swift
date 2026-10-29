/// Optimistic-concurrency request for an account relay preference update.
public struct CmxIrohRelayPreferenceUpdateRequest: Encodable, Equatable, Sendable {
    /// Last observed revision, or `nil` when creating the first preference.
    public let expectedRevision: Int64?

    /// Replacement account configuration.
    public let preference: CmxIrohAccountRelayConfiguration

    /// Creates a validated preference update.
    public init(
        expectedRevision: Int64?,
        preference: CmxIrohAccountRelayConfiguration
    ) throws {
        guard expectedRevision.map({ $0 >= 0 }) ?? true else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        self.expectedRevision = expectedRevision
        self.preference = preference
    }
}
