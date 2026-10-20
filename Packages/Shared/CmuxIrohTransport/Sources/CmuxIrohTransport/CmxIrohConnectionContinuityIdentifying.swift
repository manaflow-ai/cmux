/// Package-private access to Iroh's process-local stable connection identity.
///
/// Keeping this separate from ``CmxIrohConnection`` means alternate endpoint
/// implementations do not need to expose a native diagnostic handle.
protocol CmxIrohConnectionContinuityIdentifying: Sendable {
    func connectionContinuityID() async -> UInt64
}
