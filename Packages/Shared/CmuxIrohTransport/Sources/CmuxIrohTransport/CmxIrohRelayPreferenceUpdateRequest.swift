/// Optimistic-concurrency request for an account relay preference update.
public struct CmxIrohRelayPreferenceUpdateRequest: Encodable, Equatable, Sendable {
    /// Last observed revision, or `nil` when creating the first preference.
    public let expectedRevision: Int64?

    /// Replacement account preference.
    public let preference: CmxIrohAccountRelayPreference

    /// Creates a validated preference update.
    public init(
        expectedRevision: Int64?,
        preference: CmxIrohAccountRelayPreference
    ) throws {
        guard expectedRevision.map({ $0 >= 0 }) ?? true else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        self.expectedRevision = expectedRevision
        self.preference = preference
    }
}
