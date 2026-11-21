public import Foundation

/// A Chrome extension installed in a source profile. A Web Store install is
/// reinstalled from the store (its page opens in the target profile); an
/// unpacked one has no store copy, so its folder is copied and loaded.
public struct ImportedExtension: Sendable, Codable, Hashable, Identifiable {
    /// The 32-letter extension id (a-p).
    public var id: String
    public var name: String
    public var version: String?
    public var enabled: Bool
    /// Installed from the Chrome Web Store, so it can be reinstalled from there.
    public var fromWebStore: Bool
    /// An unpacked extension's folder in the source (absolute, outside its profile); nil for a store install.
    public var unpackedPath: String?

    public init(id: String, name: String, version: String? = nil, enabled: Bool = true, fromWebStore: Bool = true,
                unpackedPath: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.fromWebStore = fromWebStore
        self.unpackedPath = unpackedPath
    }

    /// Chrome extension ids are 32 letters from a to p.
    public static func isValidID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The extension's page in the Chrome Web Store, where Add to cmux installs it.
    public var webStorePage: URL? {
        guard fromWebStore, Self.isValidID(id) else { return nil }
        return URL(string: "https://chromewebstore.google.com/detail/\(id)")
    }
}

/// An extension a cmux browser profile already has (`chromium.installed_extensions`): an
/// import skips it, by id or, for an unpacked copy, by its folder.
public struct InstalledExtension: Sendable, Decodable, Hashable {
    public var id: String
    public var path: String?

    public init(id: String, path: String? = nil) {
        self.id = id
        self.path = path
    }
}
