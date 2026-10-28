extension MobileCoreRPCClient {
    /// Establishes the route's transport before sending any RPC requests.
    ///
    /// Iroh admission failures propagate unchanged. A successful return does
    /// not authenticate a bearer-based route or verify the RPC host identity.
    /// - Parameter timeoutNanoseconds: Dial budget; defaults to the runtime's pairing budget.
    /// - Throws: The transport's establishment error, timeout, or cancellation.
    public func connectTransport(timeoutNanoseconds: UInt64? = nil) async throws {
        try Task.checkCancellation()
        _ = try await session.ensureConnected(
            timeoutNanoseconds: timeoutNanoseconds ?? runtime.pairingRequestTimeoutNanoseconds
        )
        try Task.checkCancellation()
    }
}
