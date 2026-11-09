public import Foundation

/// The build's Cloud, made by Rust from the bundled CLI's runtime selection (cmux-tui
/// `cmux-cloud-config::config`, op `cloud_config_from_selection`): the origins and Stack
/// credentials, the sign-in callback scheme and the token store's names. Swift only reads the
/// bundle and the process environment and keeps the answer.
public struct CloudConfiguration: Sendable, Equatable {
    private static let unavailableBundleID = "com.cmuxterm.app.cloud-unavailable"

    /// Placeholder used only by test/capture composition roots that construct services before
    /// the async runtime bootstrap. A real NEXT app never reaches CloudService with this value.
    /// Its token store is its own (Rust scopes it), so it never restores a real bundle's credentials.
    public static let unavailable = CloudConfiguration(
        backend: .localOnly(inertURL), apiBaseURL: inertURL, authWebOrigin: inertURL,
        stackBaseURL: inertURL, stackProjectID: "", stackPublishableClientKey: "",
        isProductionAuth: false, callbackScheme: "cmux", bundleID: unavailableBundleID, isDebugBuild: true,
        storage: CloudStartCore().call("cloud_config_storage_names", ["bundleId": unavailableBundleID], as: StorageNames.self)
            ?? .unanswered(unavailableBundleID))

    public enum Backend: Sendable, Equatable {
        /// A production selection returned by the backend.
        case production
        /// A non-production selection returned by the backend.
        case development(URL)
        /// A loopback origin selected for local development.
        case localOnly(URL)
    }

    /// The token store's names (Rust's `StorageNames`).
    public struct StorageNames: Sendable, Equatable, Decodable {
        /// The Stack token Keychain service.
        public var keychainService: String
        /// The file-fallback token store's folder under the home folder.
        public var credentialsSubpath: [String]
        /// The suffix of every `cmux.auth.*` defaults key, when scoped.
        public var defaultsKeySuffix: String?

        /// Names no real build uses, for an FFI that did not answer.
        static func unanswered(_ bundleID: String) -> StorageNames {
            StorageNames(keychainService: "\(bundleID).auth.unanswered",
                         credentialsSubpath: ["Library", "Application Support", "cmux", bundleID, "unanswered"],
                         defaultsKeySuffix: "unanswered")
        }
    }

    /// A store an earlier version of this build used (Rust's `LegacyStore`).
    public struct LegacyStore: Sendable, Equatable, Decodable {
        public var keychainService: String
        public var credentialsSubpath: [String]
    }

    public var backend: Backend
    public var apiBaseURL: URL
    /// Origin of the web sign-in pages (`handler/native-sign-in`).
    public var authWebOrigin: URL
    public var stackBaseURL: URL
    public var stackProjectID: String
    public var stackPublishableClientKey: String
    public var isProductionAuth: Bool
    public var callbackScheme: String
    public var bundleID: String?
    public var isDebugBuild: Bool
    /// The bundled CLI's selection for this launch; nil only for ``unavailable``. Read-only: the token store's names
    /// are made from it, so another selection is another configuration (``selecting(_:)``).
    public private(set) var runtimeSelection: CloudRuntimeSelection?
    public var storage: StorageNames
    /// The namespaced store a legacy default used before #36384, adopted once.
    public var namespacedLegacyStore: LegacyStore?
    /// A signed NEXT DEV production launch adopts the running NIGHTLY's session in memory.
    public var adoptsNightlySession = false

    /// The Stack token Keychain service.
    public var keychainService: String { storage.keychainService }

    /// The file-fallback token store directory.
    public var credentialsDirectory: URL {
        credentialsDirectory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    func credentialsDirectory(homeDirectory: URL) -> URL {
        Self.directory(storage.credentialsSubpath, under: homeDirectory)
    }

    /// The namespaced store's Keychain service and folder under `homeDirectory`; nil when there is none.
    func namespacedLegacyStorage(homeDirectory: URL) -> (keychainService: String, credentialsDirectory: URL)? {
        namespacedLegacyStore.map { ($0.keychainService, Self.directory($0.credentialsSubpath, under: homeDirectory)) }
    }

    func authDefaultsKey(_ key: String) -> String {
        storage.defaultsKeySuffix.map { "\(key).\($0)" } ?? key
    }

    private static func directory(_ subpath: [String], under home: URL) -> URL {
        subpath.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// `<scheme>://auth-callback`. `/dev/null` stands in for a hand-built
    /// configuration with one that does not.
    public var callbackURL: URL { URL(string: "\(callbackScheme)://auth-callback") ?? Self.inertURL }

    /// Stands in where a literal URL failed to parse.
    static let inertURL = URL(fileURLWithPath: "/dev/null")

    /// Creates the NEXT configuration from Rust's validated client-config response.
    /// Bundle metadata controls only the native callback, never backend origins or Stack keys.
    public static func from(selection: CloudRuntimeSelection, bundle: Bundle = .main,
                            isDebugBuild: Bool) -> CloudConfiguration {
        from(selection: selection, bundleID: bundle.bundleIdentifier,
             bundled: bundle.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String] ?? [:],
             process: ProcessInfo.processInfo.environment, isDebugBuild: isDebugBuild)
    }

    /// The configuration Rust makes of `selection` for this bundle; ``unavailable`` when the FFI does not answer.
    public static func from(selection: CloudRuntimeSelection, bundleID: String?,
                            bundled: [String: String], process: [String: String],
                            isDebugBuild: Bool) -> CloudConfiguration {
        struct Request: Encodable {
            var selection: CloudRuntimeSelection, bundleId: String?, bundled: [String: String], process: [String: String]
            var isDebugBuild: Bool
        }
        struct Made: Decodable {
            struct Kind: Decodable { var kind: String, url: URL? }
            var backend: Kind, apiBaseUrl: URL, authWebOrigin: URL, stackBaseUrl: URL, stackProjectId: String
            var stackPublishableClientKey: String, isProductionAuth: Bool, callbackScheme: String, bundleId: String
            var isDebugBuild: Bool, storage: StorageNames, namespacedLegacyStore: LegacyStore?, adoptsNightlySession: Bool
        }
        let request = Request(selection: selection, bundleId: bundleID, bundled: bundled, process: process, isDebugBuild: isDebugBuild)
        guard let made = CloudStartCore().call("cloud_config_from_selection", request, as: Made.self) else { return .unavailable }
        let backend: Backend = switch (made.backend.kind, made.backend.url) {
        case ("development", let url?): .development(url)
        case ("localOnly", let url?): .localOnly(url)
        default: .production
        }
        return CloudConfiguration(
            backend: backend, apiBaseURL: made.apiBaseUrl, authWebOrigin: made.authWebOrigin,
            stackBaseURL: made.stackBaseUrl, stackProjectID: made.stackProjectId,
            stackPublishableClientKey: made.stackPublishableClientKey, isProductionAuth: made.isProductionAuth,
            callbackScheme: made.callbackScheme, bundleID: made.bundleId, isDebugBuild: made.isDebugBuild,
            runtimeSelection: selection, storage: made.storage, namespacedLegacyStore: made.namespacedLegacyStore,
            adoptsNightlySession: made.adoptsNightlySession)
    }

    /// This build's configuration for another selection, everything Rust makes of it made again (the callback
    /// scheme, which reads the bundle and the launch, is kept).
    public func selecting(_ selection: CloudRuntimeSelection) -> CloudConfiguration {
        var made = Self.from(selection: selection, bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: isDebugBuild)
        made.callbackScheme = callbackScheme
        return made
    }

    /// The selected backend's API origin. Rust has already validated and
    /// allowlisted this value before constructing the native configuration.
    public func ownerAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        runtimeSelection?.apiOrigin ?? apiBaseURL
    }

    /// The selected backend's platform origin (machine state pushes, the carrier dial). Runtime
    /// client configuration is authoritative; the API origin is the safe
    /// fallback for legacy fixtures without a runtime selection.
    public func relayAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        runtimeSelection?.platformOrigin ?? apiBaseURL
    }

    /// The selected backend's share API origin. The daemon may name the room's
    /// origin directly; native code never infers it from build kind.
    public func shareAPIBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        runtimeSelection?.shareApiOrigin ?? apiBaseURL
    }

    /// Whether a guest link's owner token may come from `api`, the API the daemon's share room names:
    /// only the selected backend's share API.
    public func acceptsShareAPI(_ api: URL) -> Bool {
        api == shareAPIBaseURL()
    }

    /// Hosted sign-in entry (Rust's `sign_in_url`): `handler/native-sign-in` wraps Stack sign-in and
    /// returns to `<scheme>://auth-callback` through `handler/after-sign-in`.
    public func signInURL(callbackState: String?) -> URL {
        struct Request: Encodable { var authWebOrigin: String, callbackScheme: String, state: String? }
        struct Reply: Decodable { var url: String }
        let request = Request(authWebOrigin: authWebOrigin.absoluteString, callbackScheme: callbackScheme, state: callbackState)
        let entryPage = authWebOrigin.appendingPathComponent("handler/native-sign-in")
        return CloudStartCore().call("cloud_config_sign_in_url", request, as: Reply.self).flatMap { URL(string: $0.url) } ?? entryPage
    }
}
