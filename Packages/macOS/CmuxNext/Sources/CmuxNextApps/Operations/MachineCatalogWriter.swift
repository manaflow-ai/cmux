public import CmuxNextDaemon

/// Publishes on an existing captured owner connection; it never starts or substitutes a carrier.
public nonisolated protocol MachineCatalogWriter: AnyObject, Sendable {
    /// Sends a bounded, sequenced route projection to its fenced local owner.
    /// - Parameter request: The exact owner, sequence and records to publish.
    /// - Throws: Capability, authority, stale-owner, cancellation or transport refusals.
    func publishMachineCatalog(_ request: MachineCatalogPublishRequest) async throws
}
