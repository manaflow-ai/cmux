public import Foundation

/// Signed-in Stack account the host registers under. The App implements it
/// over its auth coordinator; tokens are fetched per request, never cached here.
public protocol MobileHostAuth: Sendable {
    /// Stack project the account belongs to (part of the v2 device identity).
    var projectID: String { get }
    var userID: String { get }
    var teamID: String { get }
    func accessToken(forceRefresh: Bool) async throws -> String
    /// False once the user signed out or switched team; the host stops.
    func isCurrent() async -> Bool
}

/// Static inputs for one Mac host installation (plans/cmux-next/cloud-ios.md
/// section 2.2). `namespace` is the bundle id: the v2 device identity and its
/// keys are keyed on it, exactly like the old app, so a tagged cmux-next
/// build is one v2 Mac device per bundle.
public struct MobileHostConfiguration: Sendable {
    public enum KeyStorage: Sendable {
        /// Files under `stateDirectory` (DEBUG builds: no Keychain prompts per tag).
        case files
        /// The shared v2 Keychain services (`<namespace>.cmux-iroh-v2.*`).
        case keychain
    }

    public var baseURL: URL
    public var environment: String
    public var namespace: String
    public var tag: String
    public var stateDirectory: URL
    public var keyStorage: KeyStorage
    public var preferredPort: Int
    public var displayName: String
    public var appVersion: String
    public var appBuild: String
    /// Local daemon socket for the daemon lane (`resource` "local").
    public var daemonSocketPath: @Sendable () async -> String?

    public init(baseURL: URL, environment: String, namespace: String, tag: String,
                stateDirectory: URL, keyStorage: KeyStorage, preferredPort: Int = 0, displayName: String,
                appVersion: String, appBuild: String, daemonSocketPath: @escaping @Sendable () async -> String?) {
        self.baseURL = baseURL
        self.environment = environment
        self.namespace = namespace
        self.tag = tag
        self.stateDirectory = stateDirectory
        self.keyStorage = keyStorage
        self.preferredPort = preferredPort
        self.displayName = displayName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.daemonSocketPath = daemonSocketPath
    }

    /// The v2 control-plane origin for an environment name.
    public static func baseURL(environment: String) -> URL? {
        switch environment {
        case "production": URL(string: "https://cmux-v2.debussy.workers.dev")
        case "staging": URL(string: "https://cmux-v2-staging.debussy.workers.dev")
        case "development": URL(string: "https://cmux-v2-development.debussy.workers.dev")
        default: nil
        }
    }
}
