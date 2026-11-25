public import Foundation

/// Rust's validated, non-secret client-config selection returned by the bundled CLI.
/// Swift decodes this value and hands it back to Rust (camelCase) for the configuration it makes;
/// backend discovery, allowlisting and cached fallback belong to Rust.
public struct CloudRuntimeSelection: Codable, Sendable, Equatable {
    public var name: String
    public var apiOrigin: URL
    public var authWebOrigin: URL
    public var vmOrigin: URL
    public var platformOrigin: URL
    public var mobileOrigin: URL
    public var deviceHubOrigin: URL
    public var shareRoomOrigin: URL
    public var shareApiOrigin: URL
    public var stackOrigin: URL
    public var stackProjectId: String
    public var stackClientKey: String
    public var bundleId: String
    public var mutable: Bool
    public var authNamespace: String
    public var authStorageNamespace: String?
    public var legacyStorage: Bool
    public var configSource: String?
    public var clientConfigVersion: Int?
    public var imageChannel: String?
    /// Where this launch's backend came from when it is not the bundle's own choice (Rust
    /// `Selection::backend_override`): `launch` (`--cloud-backend`, `CMUX_NEXT_CLOUD_BACKEND`) or
    /// `tag_file` (a dev build's `backend.json`, written by the tag's hand-off). Nil: the picker's
    /// choice or the default.
    public var backendOverride: String?

    public init(name: String, apiOrigin: URL, authWebOrigin: URL, vmOrigin: URL, platformOrigin: URL,
                mobileOrigin: URL, deviceHubOrigin: URL, shareRoomOrigin: URL, shareApiOrigin: URL,
                stackOrigin: URL, stackProjectId: String, stackClientKey: String, bundleId: String,
                mutable: Bool, authNamespace: String, legacyStorage: Bool, configSource: String? = nil,
                clientConfigVersion: Int? = nil, imageChannel: String? = nil, authStorageNamespace: String? = nil,
                backendOverride: String? = nil) {
        self.name = name; self.apiOrigin = apiOrigin; self.authWebOrigin = authWebOrigin; self.vmOrigin = vmOrigin
        self.platformOrigin = platformOrigin; self.mobileOrigin = mobileOrigin; self.deviceHubOrigin = deviceHubOrigin
        self.shareRoomOrigin = shareRoomOrigin; self.shareApiOrigin = shareApiOrigin; self.stackOrigin = stackOrigin
        self.stackProjectId = stackProjectId; self.stackClientKey = stackClientKey; self.bundleId = bundleId
        self.mutable = mutable; self.authNamespace = authNamespace; self.legacyStorage = legacyStorage
        self.authStorageNamespace = authStorageNamespace
        self.configSource = configSource; self.clientConfigVersion = clientConfigVersion
        self.imageChannel = imageChannel
        self.backendOverride = backendOverride
    }

    /// The line a dev build shows for its Cloud backend (Settings > Accounts, `auth.status`
    /// `backend_label`): the API origin, and where an override came from. Nil for a bundle that
    /// cannot change its backend (release, RC): those never show it.
    public var developerBackendLabel: String? {
        guard mutable else { return nil }
        let origin = apiOrigin.absoluteString
        switch backendOverride {
        case "tag_file": return "\(origin) (this tag's backend.json)"
        case "launch": return "\(origin) (launch override)"
        default: return name == origin ? origin : "\(origin) (\(name))"
        }
    }

    /// Rust permits historical pairing and install state only for a known,
    /// untouched default. Every explicit selection has its own namespace.
    public var storageNamespace: String? { legacyStorage ? nil : authNamespace }

    /// Decodes the CLI's JSON response without maintaining another environment table.
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}
