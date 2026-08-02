#if DEBUG
internal import CMUXMobileCore

extension MobileCoreRPCSession {
    /// Returns the process-local identity of the exact installed native
    /// transport. This does not create or reconnect a transport.
    func transportContinuityID() async -> UInt64? {
        guard let transport = transport as? any CmxByteTransportContinuityIdentifying else {
            return nil
        }
        return await transport.transportContinuityID()
    }

    /// Captures close notification for the exact currently installed native
    /// transport. A later reconnect cannot substitute a different connection.
    func transportClosureObservation() async -> CmxTransportClosureObservation? {
        guard let transport = transport as? any CmxByteTransportClosureObserving else {
            return nil
        }
        return await transport.transportClosureObservation()
    }
}
#endif
