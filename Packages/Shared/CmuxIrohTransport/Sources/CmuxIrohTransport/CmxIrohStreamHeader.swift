/// The authenticated lane declaration at the beginning of every Iroh stream.
public struct CmxIrohStreamHeader: Equatable, Sendable {
    /// The application lane carried by the stream.
    public let lane: CmxIrohLane

    /// The admission proof carried only on the first control stream.
    ///
    /// `nil` on a control lane requests allowlist admission: the Mac may admit
    /// the TLS-proven EndpointID directly from its persisted paired-peer
    /// allowlist, with no in-band credential.
    public let credential: CmxIrohAdmissionCredential?

    /// Creates a validated stream header.
    ///
    /// - Parameters:
    ///   - lane: The lane this stream will carry.
    ///   - credential: The control-stream admission proof, or `nil` for
    ///     allowlist admission of an already-paired endpoint.
    /// - Throws: ``CmxIrohStreamHeaderError`` for an invalid lane and credential combination.
    public init(
        lane: CmxIrohLane,
        credential: CmxIrohAdmissionCredential? = nil
    ) throws {
        switch (lane, credential) {
        case (.control, _):
            break
        case (_, .some):
            throw CmxIrohStreamHeaderError.credentialOnNonControlLane
        case (_, nil):
            break
        }
        self.lane = lane
        self.credential = credential
    }
}
