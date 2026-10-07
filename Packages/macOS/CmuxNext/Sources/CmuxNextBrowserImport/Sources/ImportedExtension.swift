public import Foundation

/// A Chrome extension installed in a source profile. cmux cannot copy an
/// installed extension; it reinstalls it from the Chrome Web Store.
public struct ImportedExtension: Sendable, Codable, Hashable, Identifiable {
    /// The 32-letter extension id (a-p).
    public var id: String
    public var name: String
    public var version: String?
    public var enabled: Bool
    /// Installed from the Chrome Web Store, so it can be reinstalled from there.
    public var fromWebStore: Bool

    public init(id: String, name: String, version: String? = nil, enabled: Bool = true, fromWebStore: Bool = true) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.fromWebStore = fromWebStore
    }

    /// The extension's Chrome Web Store page, where Chromium installs it.
    public var webStoreURL: URL {
        URL(string: "https://chromewebstore.google.com/detail/\(id)")!
    }

    /// Chrome extension ids are 32 letters from a to p.
    public static func isValidID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }
}
