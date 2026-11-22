/// Why the remote desktop core refused a call (the `CMUX_RD_ERR_*` codes).
public nonisolated enum RemoteRdCoreError: Error, Sendable, Hashable {
    /// A required buffer was missing.
    case null
    /// The bytes are not valid `cmux.rd/1`.
    case invalid
    /// An output buffer was too small (the wrapper retries; never thrown to callers).
    case buffer
    /// The call does not match the receiver's carrier.
    case carrier
    /// The stream broke or the host flooded the queues; end the session.
    case failed
    /// An internal error; the receiver is unusable.
    case panic
    /// The stream is not open, or the stream limit is reached.
    case stream
    /// An upstream sender has no consent for its media kind.
    case consent
    /// A bulk queue or the open transfer limit is full.
    case full
    /// A code this wrapper does not know.
    case unknown(Int32)

    init(code: Int32) {
        switch code {
        case -1: self = .null
        case -2: self = .invalid
        case -3: self = .buffer
        case -4: self = .carrier
        case -5: self = .failed
        case -6: self = .panic
        case -7: self = .stream
        case -8: self = .consent
        case -9: self = .full
        default: self = .unknown(code)
        }
    }

    /// Returns `code` when it is a result (non-negative), else throws.
    static func check(_ code: Int32) throws(RemoteRdCoreError) -> Int {
        guard code >= 0 else { throw RemoteRdCoreError(code: code) }
        return Int(code)
    }
}
