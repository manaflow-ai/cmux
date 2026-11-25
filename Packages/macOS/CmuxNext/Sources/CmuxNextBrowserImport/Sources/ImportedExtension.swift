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

/// What importing extensions does in one cmux profile (`chromium.extension_install_plan`, the
/// daemon's reader): the Web Store installs and unpacked folders it lacks. What it has already
/// (by id, or an unpacked copy by its folder) is left alone, so a second import adds nothing twice.
public struct ExtensionInstallPlan: Sendable, Decodable, Equatable {
    /// An unpacked extension and the folder its copy goes to.
    public struct Copy: Sendable, Decodable, Equatable {
        public var `extension`: ImportedExtension
        public var copy: String
    }

    public var store: [ImportedExtension]
    public var unpacked: [Copy]
    /// Extensions the profile already has.
    public var installed: Int

    public init(store: [ImportedExtension] = [], unpacked: [Copy] = [], installed: Int = 0) {
        self.store = store
        self.unpacked = unpacked
        self.installed = installed
    }
}
