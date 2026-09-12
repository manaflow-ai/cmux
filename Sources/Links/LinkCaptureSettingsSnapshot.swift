import Foundation

struct LinkCaptureSettingsSnapshot: Equatable, Sendable {
    var enabled: Bool
    var includeFilePaths: Bool
    var ignoreHosts: [String]
    var retentionLimit: Int
    var fetchTitles: Bool

    var ingestConfiguration: WorkspaceLinksIngestConfiguration {
        WorkspaceLinksIngestConfiguration(
            includeFilePaths: includeFilePaths,
            ignoreHosts: ignoreHosts,
            retentionLimit: retentionLimit
        )
    }
}
