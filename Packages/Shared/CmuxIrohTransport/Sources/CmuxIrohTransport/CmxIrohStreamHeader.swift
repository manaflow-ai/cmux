/// The authenticated lane declaration at the beginning of every Iroh stream.
public struct CmxIrohStreamHeader: Equatable, Sendable {
    /// The application lane carried by the stream.
    public let lane: CmxIrohLane

    /// The admission proof, present only on the first control stream.
    public let credential: CmxIrohAdmissionCredential?

    /// Creates a validated stream header.
    ///
    /// - Parameters:
    ///   - lane: The lane this stream will carry.
    ///   - credential: The control-stream admission proof.
    /// - Throws: ``CmxIrohStreamHeaderError`` for an invalid lane and credential combination.
    public init(
        lane: CmxIrohLane,
        credential: CmxIrohAdmissionCredential? = nil
    ) throws {
        switch (lane, credential) {
        case (.control, nil):
            throw CmxIrohStreamHeaderError.missingControlCredential
        case (.control, .some):
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
