/// The authenticated lane declaration at the beginning of every Iroh stream.
public struct CmxIrohStreamHeader: Equatable, Sendable {
    /// The application lane carried by the stream.
    public let lane: CmxIrohLane

    /// The admission proof, present only on the first control stream.
    public let credential: CmxIrohAdmissionCredential?

    /// Late-predecessor fence, present on modern initial control streams.
    public let connectionAttempt: CmxIrohConnectionAttempt?

    /// Creates a validated stream header.
    ///
    /// - Parameters:
    ///   - lane: The lane this stream will carry.
    ///   - credential: The control-stream admission proof.
    /// - Throws: ``CmxIrohStreamHeaderError`` for an invalid lane and credential combination.
    public init(
        lane: CmxIrohLane,
        credential: CmxIrohAdmissionCredential? = nil,
        connectionAttempt: CmxIrohConnectionAttempt? = nil
    ) throws {
        switch (lane, credential, connectionAttempt) {
        case (.control, nil, _):
            throw CmxIrohStreamHeaderError.missingControlCredential
        case (.control, .some, _):
            break
        case (.controlReplacement, .some, _):
            throw CmxIrohStreamHeaderError.credentialOnNonControlLane
        case (_, .some, _):
            throw CmxIrohStreamHeaderError.credentialOnNonControlLane
        case (_, nil, .some):
            throw CmxIrohStreamHeaderError.attemptOnNonControlLane
        case (_, nil, nil):
            break
        }
        self.lane = lane
        self.credential = credential
        self.connectionAttempt = connectionAttempt
    }
}
