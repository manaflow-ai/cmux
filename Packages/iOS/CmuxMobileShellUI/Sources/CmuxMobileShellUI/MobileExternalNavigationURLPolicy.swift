import CMUXMobileCore
import Foundation

#if os(iOS)
/// URL-scheme policy for iOS workspace navigation links.
enum MobileExternalNavigationURLPolicy {
    /// The historical schemes plus the exact scheme registered by this bundle.
    /// Keeping the set explicit prevents a random custom scheme from entering
    /// the workspace router or bypassing the pairing URL gate.
    static var supportedSchemes: Set<String> {
        var schemes = Set(CmxPairingURLScheme.all)
        if let current = CmxPairingURLSchemeResolver().resolved?.rawValue {
            schemes.insert(current)
        }
        return schemes
    }

    /// Whether a raw URL is a recognized navigation route, including malformed
    /// routes that should be consumed rather than sent to pairing.
    static func recognizes(_ rawURL: String?) -> Bool {
        guard let rawURL, let url = URL(string: rawURL) else { return false }
        switch CmxNavigationURLRequest.parse(url, supportedSchemes: supportedSchemes) {
        case .success(nil):
            return false
        case .success(.some), .failure:
            return true
        }
    }
}
#endif
