/// Errors raised while decoding a Cloud VM attach endpoint.
public enum CmxCloudAttachError: Error, Equatable, Sendable {
    /// The response declares a transport other than the current cmux-remote contract.
    case unsupportedTransport(String)
}
