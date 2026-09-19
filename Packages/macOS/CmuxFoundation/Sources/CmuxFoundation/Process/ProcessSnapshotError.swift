/// A process census that could not satisfy a request.
public enum ProcessSnapshotError: Error {
    /// Sampling exceeded the consumer's maximum age before delivery.
    case expired
    /// The fixed request admission bound was reached.
    case overloaded
}
