/// Why ``ReactGrabScriptLoader`` refused the react-grab library.
public nonisolated enum ReactGrabError: Error, Hashable, Sendable {
    /// The downloaded file's SHA-256 is not the pinned hash, so it is not run.
    case integrityMismatch
    /// The downloaded file is not UTF-8 text.
    case notText
    /// The version does not make a valid download URL.
    case badVersion
}
