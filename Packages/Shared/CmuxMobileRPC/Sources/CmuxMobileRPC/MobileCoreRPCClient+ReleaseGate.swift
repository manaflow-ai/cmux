#if DEBUG
public import CMUXMobileCore

extension MobileCoreRPCClient {
    /// Returns a process-local identifier for the exact installed native
    /// transport, when the active transport supports continuity inspection.
    ///
    /// The value is intentionally opaque and is used only by local release
    /// gates. It must not be persisted or included in diagnostic reports.
    public func transportContinuityID() async -> UInt64? {
        await session.transportContinuityID()
    }

    /// Captures a close signal for the exact installed native transport.
    /// The observation remains bound to that connection across RPC teardown.
    public func transportClosureObservation() async -> CmxTransportClosureObservation? {
        await session.transportClosureObservation()
    }
}
#endif
