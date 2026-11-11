import Foundation

/// The exact classic snapshot shown for confirmation and restored after it.
public nonisolated struct ClassicImportPlan: Sendable {
    public nonisolated enum Source: Sendable {
        case stable
        case nightly
        case releaseCandidate
        case staging
        case debug

        /// The classic app's name as its Dock shows it.
        public var appName: String {
            switch self {
            case .stable: "cmux"
            case .nightly: "cmux NIGHTLY"
            case .releaseCandidate: "cmux RC"
            case .staging: "cmux STAGING"
            case .debug: "cmux DEV"
            }
        }

        /// A fixed technical identifier, never the untrusted source filename.
        public var fileName: String {
            switch self {
            case .stable: "session-com.cmuxterm.app.json"
            case .nightly: "session-com.cmuxterm.app.nightly.json"
            case .releaseCandidate: "session-com.cmuxterm.app.rc.json"
            case .staging: "session-com.cmuxterm.app.staging.json"
            case .debug: "session-com.cmuxterm.app.debug.json"
            }
        }
    }

    public let source: Source
    /// When classic saved the session this imports (seconds since 1970).
    public let savedAt: Double
    /// Whether that classic app is open now: this is its last autosave, not its quit save.
    public let classicRunning: Bool
    public let workspaces: [ClassicSessionWorkspace]
    public let skippedCloudVMs: Int
    public let cleanupWorkspaces: Int

    public init(source: ClassicMigrationSource, migration: ClassicMigrationPlan, classicRunning: Bool = false) {
        self.source = Self.source(source.bundleID)
        savedAt = source.modifiedAt
        self.classicRunning = classicRunning
        workspaces = migration.windows.flatMap(\.workspaces)
        skippedCloudVMs = migration.skipped.values.count { $0 == .cloudVM }
        cleanupWorkspaces = migration.cleanup.count
    }

    public var browserTabs: Int { tabs.count { $0.url != nil } }
    public var localFilePages: Int {
        tabs.count { $0.url.flatMap(URL.init(string:))?.isFileURL == true }
    }
    public var sshWorkspaces: Int { workspaces.count { $0.remote != nil } }
    public var agentChats: Int {
        workspaces.filter { $0.remote == nil && $0.cloudVM == nil }
            .flatMap(\.layout.tabs).count { $0.agent != nil }
    }
    private var tabs: [ClassicSessionTab] { workspaces.flatMap(\.layout.tabs) }

    /// The classic app that saves under `bundle` (a classic bundle id).
    public static func source(_ bundle: String) -> Source {
        if bundle == ClassicSessionImporter.stableBundleIdentifier { return .stable }
        if bundle == "com.cmuxterm.app.nightly" || bundle.hasPrefix("com.cmuxterm.app.nightly.") { return .nightly }
        if bundle == "com.cmuxterm.app.rc" || bundle.hasPrefix("com.cmuxterm.app.rc.") { return .releaseCandidate }
        if bundle == "com.cmuxterm.app.staging" || bundle.hasPrefix("com.cmuxterm.app.staging.") { return .staging }
        return .debug
    }
}
