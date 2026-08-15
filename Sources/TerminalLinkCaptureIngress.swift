import CmuxFoundation
import CmuxTerminalCore
import Foundation
import os

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

enum LinksCaptureSettings {
    static let enabledKey = "links.enabled"
    static let ignoreHostsKey = "links.ignoreHosts"
    static let includeFilePathsKey = "links.includeFilePaths"
    static let retentionLimitKey = "links.retentionLimit"
    static let fetchTitlesKey = "links.fetchTitles"

    static let defaultEnabled = true
    static let defaultIgnoreHosts = "localhost:31034"
    static let defaultIncludeFilePaths = false
    static let defaultRetentionLimit = 500
    static let defaultFetchTitles = false

    static func snapshot(defaults: UserDefaults = .standard) -> LinkCaptureSettingsSnapshot {
        LinkCaptureSettingsSnapshot(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled,
            includeFilePaths: defaults.object(forKey: includeFilePathsKey) as? Bool ?? defaultIncludeFilePaths,
            ignoreHosts: parseIgnoreHosts(
                defaults.string(forKey: ignoreHostsKey) ?? defaultIgnoreHosts
            ),
            retentionLimit: WorkspaceLinksIngestConfiguration.clampedRetentionLimit(
                defaults.object(forKey: retentionLimitKey) as? Int ?? defaultRetentionLimit
            ),
            fetchTitles: defaults.object(forKey: fetchTitlesKey) as? Bool ?? defaultFetchTitles
        )
    }

    static func parseIgnoreHosts(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum TerminalLinkCaptureGate {
    // Lock carve-out: the Ghostty PTY tee callback is synchronous and non-async,
    // so it needs a short snapshot read without hopping actors on each byte chunk.
    private static let enabledGate = AtomicBooleanGate(LinksCaptureSettings.snapshot().enabled)
    private static let snapshotLock = OSAllocatedUnfairLock(
        initialState: LinksCaptureSettings.snapshot()
    )
    private static let defaultsObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification,
        object: nil,
        queue: .main
    ) { _ in
        TerminalLinkCaptureGate.refreshFromUserDefaults()
    }

    static func isEnabled() -> Bool {
        _ = defaultsObserver
        return enabledGate.loadAcquire()
    }

    static func currentSnapshot() -> LinkCaptureSettingsSnapshot {
        _ = defaultsObserver
        return snapshotLock.withLock { $0 }
    }

    static func refreshFromUserDefaults() {
        _ = defaultsObserver
        let snapshot = LinksCaptureSettings.snapshot()
        snapshotLock.withLock { $0 = snapshot }
        enabledGate.storeRelease(snapshot.enabled)
    }
}

@MainActor
final class TerminalLinkCaptureIngress {
    static let shared = TerminalLinkCaptureIngress()

    private init() {}

    func ingest(
        _ links: [TerminalCapturedLink],
        workspaceID: UUID,
        sourcePanelId: UUID?,
        settings: LinkCaptureSettingsSnapshot
    ) {
        guard settings.enabled, !links.isEmpty,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceID) else {
            return
        }
        let sourceTitle = sourcePanelId.flatMap { workspace.panelTitles[$0] }
        for link in links {
            workspace.linksState.ingest(
                url: link.url,
                origin: WorkspaceCapturedLinkOrigin(link.source),
                sourcePanelId: sourcePanelId,
                sourceSurfaceTitle: sourceTitle,
                configuration: settings.ingestConfiguration
            )
        }
    }
}
