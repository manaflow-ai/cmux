/// Validation failures produced before any text input reaches the worker.
public enum SimulatorTextInputEncodingError: Error, Equatable, Sendable {
    /// The source string contains no encodable characters.
    case empty
    /// The source exceeds the protocol's UTF-8 byte ceiling.
    case tooLong(actualUTF8ByteCount: Int, maximumUTF8ByteCount: Int)
    /// A scalar has no representation in the supported US keyboard layout.
    case unsupportedScalar(value: UInt32, scalarIndex: Int)
    /// The generated event sequence is unbalanced or otherwise invalid.
    case malformedSequence
}
