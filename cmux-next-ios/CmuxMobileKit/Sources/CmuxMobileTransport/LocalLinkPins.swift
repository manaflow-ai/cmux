#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import Foundation

/// Tells the Rust core which identity key each paired Mac has (ultra-connectivity P7), so a dial
/// with no internet trusts only a nearby ad that carries that key's tag (`local_link_pair` in
/// `cmux-mobile-link-ffi` `local_link.rs`). A thin shim; nothing where the core is not linked.
public enum LocalLinkPins {
    /// The phone pinned `identityKey` (X9.63, lowercase hex) for Mac `mac`, or forgot it (nil).
    public static func pair(mac: String, identityKey: String?) {
        #if canImport(CmuxMobileLinkFFI)
        localLinkPair(macDeviceId: mac, identityPublicKey: identityKey.map { Data($0.lowercased().utf8) })
        #endif
    }
}
