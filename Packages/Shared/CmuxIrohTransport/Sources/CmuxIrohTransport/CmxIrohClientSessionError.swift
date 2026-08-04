/// Failures while establishing or operating a cmux Iroh client session.
public enum CmxIrohClientSessionError: Error, Equatable, Sendable {
    /// The QUIC peer identity did not match the requested EndpointID.
    case remoteIdentityMismatch

    /// The peer denied the signed admission credential.
    case admissionDenied(code: UInt16)

    /// The peer closed a stream before its fixed framing completed.
    case unexpectedEndOfStream

    /// A role-invalid frame appeared during the admission barrier.
    case invalidAdmissionFrame

    /// An operation required an admitted control stream.
    case notConnected

    /// The session was explicitly closed.
    case alreadyClosed

    /// A read bound was zero or negative.
    case invalidMaximumByteCount(Int)

    /// The requested outgoing lane must be terminal or artifact data.
    case invalidOutgoingLane

    /// This protocol configuration has no production owner for application lanes.
    case applicationLanesUnavailable
}
