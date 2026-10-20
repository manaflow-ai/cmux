/// Admission policy for active Iroh sessions owned by one broker binding.
///
/// The host keeps the authoritative connection collection. This value only
/// evaluates that collection, so quota state cannot drift when a connection is
/// closed, revoked, or removed in bulk.
public struct CmxIrohActiveBindingConnectionQuota: Sendable {
    /// Two sessions permit a live client to overlap its replacement connection
    /// during route migration or reconnect without monopolizing the host pool.
    public static let recommendedMaximumActiveConnectionsPerBinding = 2

    public let maximumActiveConnectionsPerBinding: Int

    public init(
        maximumActiveConnectionsPerBinding: Int = Self
            .recommendedMaximumActiveConnectionsPerBinding
    ) {
        precondition(maximumActiveConnectionsPerBinding > 0)
        self.maximumActiveConnectionsPerBinding = maximumActiveConnectionsPerBinding
    }

    /// Returns whether one more session for `bindingID` fits within the quota.
    ///
    /// The caller must evaluate and insert while holding the same synchronization
    /// boundary so concurrent admissions cannot both consume the final slot.
    public func allowsAdmission<ActiveBindingIDs: Sequence>(
        for bindingID: String,
        activeBindingIDs: ActiveBindingIDs
    ) -> Bool where ActiveBindingIDs.Element == String {
        var matchingConnectionCount = 0
        for activeBindingID in activeBindingIDs where activeBindingID == bindingID {
            matchingConnectionCount += 1
            if matchingConnectionCount >= maximumActiveConnectionsPerBinding {
                return false
            }
        }
        return true
    }
}
