/// The narrowest network scope in which an Iroh path hint may be disclosed.
public enum CmxIrohPathHintPrivacyScope: String, Codable, Sendable {
    /// The hint is safe to publish through Internet discovery.
    case publicInternet = "public_internet"
    /// The hint may be shared only on the current local network.
    case localNetwork = "local_network"
    /// The hint may be shared only through the user's private network.
    case privateNetwork = "private_network"
}
