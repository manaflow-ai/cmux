public import Foundation

/// Compatibility gates for authenticated Mac-to-Mac links.
///
/// A descriptor in a v2 directory is signed by the owning Mac at enrollment
/// (and again for metadata changes). The Worker also records the rule it used
/// to construct the directory. Cross-channel links therefore require both
/// signed descriptors to opt into this protocol version and the directory to
/// name the corresponding server rule. Unsigned presence data is never passed
/// to this helper.
public enum IrxMacPeerCompatibility {
    /// Signed capability advertised by Mac metadata that understands the
    /// channel-independent Mac peer contract.
    public static let capability = "cmux.mac-peer.v1"

    /// Team directory rule for channel-independent Mac peer admission.
    public static let teamCrossChannelRule = "cmux.mac-peer-cross-channel.v1"

    /// Per-account directory rule for channel-independent Mac peer admission.
    public static let accountCrossChannelRule = "cmux.mac-account-cross-channel.v1"

    /// Whether two Mac descriptors may use a channel-independent Mac peer
    /// permission from a directory carrying `rule`.
    ///
    /// Exact namespace and build matches remain compatible with older clients
    /// and do not require the new capability or rule. A mismatch is allowed
    /// only when both complete descriptors carry the signed capability and
    /// the issuing directory explicitly names the matching rule.
    public static func channelsCompatible(
        local: V2DeviceDescriptor,
        peer: V2DeviceDescriptor,
        rule: String,
        directoryRules: [String]
    ) -> Bool {
        guard local.metadata.platform == .mac, peer.metadata.platform == .mac else { return false }
        if local.identity.appNamespace == peer.identity.appNamespace,
           local.identity.buildTag == peer.identity.buildTag {
            return true
        }
        guard directoryRules.contains(rule) else { return false }
        return local.metadata.capabilities.contains(capability)
            && peer.metadata.capabilities.contains(capability)
    }
}
