import Foundation

#if DEBUG
/// User-facing strings of remote tabs (Localizable.xcstrings of this module).
public nonisolated struct RemoteBrowserStrings {
    public nonisolated init() {}
    /// The refusal for an address that is not a loopback host port.
    public static func addressNotRecognized(_ address: String) -> String {
        String(format: String(localized: "remoteBrowser.refusal.address", defaultValue: "Not a loopback host address: %@", bundle: .module), address)
    }
}
#endif
