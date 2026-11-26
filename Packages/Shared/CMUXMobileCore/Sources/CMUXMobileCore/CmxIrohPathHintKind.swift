/// The address form carried by an Iroh path hint.
public enum CmxIrohPathHintKind: String, Codable, Sendable {
    /// A socket address that Iroh may try directly.
    case directAddress = "direct_address"
    /// A legacy relay identifier understood by the Iroh integration.
    case relayIdentifier = "relay_identifier"
    /// A relay server URL.
    case relayURL = "relay_url"
}
