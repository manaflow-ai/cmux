import CmuxNextOnboarding
import Foundation

/// The exact classic snapshot shown for confirmation and restored after it.
struct ClassicImportPlan: Sendable {
    enum Source: Sendable {
        case stable
        case nightly
        case releaseCandidate
        case staging
        case debug

        /// A fixed technical identifier, never the untrusted source filename.
        var fileName: String {
            switch self {
            case .stable: "session-com.cmuxterm.app.json"
            case .nightly: "session-com.cmuxterm.app.nightly.json"
            case .releaseCandidate: "session-com.cmuxterm.app.rc.json"
            case .staging: "session-com.cmuxterm.app.staging.json"
            case .debug: "session-com.cmuxterm.app.debug.json"
            }
        }
    }

    let source: Source
    let workspaces: [ClassicSessionWorkspace]
    let skippedCloudVMs: Int
    let cleanupWorkspaces: Int

    init(source: ClassicMigrationSource, migration: ClassicMigrationPlan) {
        self.source = Self.source(source.bundleID)
        workspaces = migration.windows.flatMap(\.workspaces)
        skippedCloudVMs = migration.skipped.values.count { $0 == .cloudVM }
        cleanupWorkspaces = migration.cleanup.count
    }

    var browserTabs: Int { tabs.count { $0.url != nil } }
    var localFilePages: Int {
        tabs.count { $0.url.flatMap(URL.init(string:))?.isFileURL == true }
    }
    var sshWorkspaces: Int { workspaces.count { $0.remote != nil } }
    var agentChats: Int {
        workspaces.filter { $0.remote == nil && $0.cloudVM == nil }
            .flatMap(\.layout.tabs).count { $0.agent != nil }
    }
    private var tabs: [ClassicSessionTab] { workspaces.flatMap(\.layout.tabs) }

    private static func source(_ bundle: String) -> Source {
        if bundle == ClassicSessionImporter.stableBundleIdentifier { return .stable }
        if bundle == "com.cmuxterm.app.nightly" || bundle.hasPrefix("com.cmuxterm.app.nightly.") { return .nightly }
        if bundle == "com.cmuxterm.app.rc" || bundle.hasPrefix("com.cmuxterm.app.rc.") { return .releaseCandidate }
        if bundle == "com.cmuxterm.app.staging" || bundle.hasPrefix("com.cmuxterm.app.staging.") { return .staging }
        return .debug
    }
}
