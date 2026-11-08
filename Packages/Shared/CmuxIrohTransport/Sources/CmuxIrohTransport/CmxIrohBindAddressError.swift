/// Validation failures for a stable Iroh UDP bind address.
public enum CmxIrohBindAddressError: Error, Equatable, Sendable {
    /// The host is not an unbracketed numeric IPv4 or IPv6 literal.
    case invalidIPAddress

    /// Port zero belongs to the endpoint's ephemeral bind policy.
    case zeroPort
}
