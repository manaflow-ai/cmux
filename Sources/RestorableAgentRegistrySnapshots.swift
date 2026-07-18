import CmuxFoundation
import Foundation

extension RestorableAgentSessionIndex {
    /// Ensures the durable registry has seen the legacy providers referenced by
    /// persisted hibernation placeholders before any panel can adopt one. This
    /// only stats/parses those providers; it does not scan transcripts or the
    /// process table and does not materialize registry history.
    @discardableResult
    static func prepareAgentRegistryForSessionRestore(
        _ snapshot: inout AppSessionSnapshot,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<RestorableAgentKind> {
        var kinds = Set<RestorableAgentKind>()
        for window in snapshot.windows.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            for workspace in window.tabManager.workspaces.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
                for panel in workspace.panels.prefix(SessionPersistencePolicy.maxPanelsPerWorkspace) {
                    guard panel.terminal?.hibernation != nil,
                          let kind = panel.terminal?.agent?.kind else { continue }
                    kinds.insert(kind)
                }
            }
        }
        guard !kinds.isEmpty else { return [] }

        let sources = kinds
            .sorted { $0.rawValue < $1.rawValue }
            .map {
                CmuxAgentSessionRegistry.LegacySource(
                    provider: $0.rawValue,
                    url: $0.hookStoreFileURL(
                        homeDirectory: homeDirectory,
                        environment: environment
                    )
                )
            }
        let registry = CmuxAgentSessionRegistry(
            url: CmuxAgentSessionRegistry.defaultURL(
                homeDirectory: homeDirectory,
                environment: environment
            ),
            busyTimeoutMilliseconds: 25
        )
        let failedProviders: Set<String>
        do {
            let result = try registry.refreshLegacySources(sources, fileManager: fileManager)
            failedProviders = result.failedProviders
            if !failedProviders.isEmpty {
                NSLog(
                    "[SessionRestore] legacy agent registry preparation skipped providers=%@",
                    failedProviders.sorted().joined(separator: ",")
                )
            }
        } catch {
            NSLog("[SessionRestore] agent registry preparation unavailable error=%@", String(describing: error))
            failedProviders = Set(kinds.map(\.rawValue))
        }
        guard !failedProviders.isEmpty else { return [] }

        // Remove only the providers whose durable ownership could not be
        // verified. This makes every affected panel a plain shell before
        // construction, so one failed batch preflight cannot turn into one
        // SQLite busy wait per restored panel.
        for windowIndex in snapshot.windows.indices.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            for workspaceIndex in snapshot.windows[windowIndex]
                .tabManager.workspaces.indices.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
                for panelIndex in snapshot.windows[windowIndex]
                    .tabManager.workspaces[workspaceIndex]
                    .panels.indices.prefix(SessionPersistencePolicy.maxPanelsPerWorkspace) {
                    guard var terminal = snapshot.windows[windowIndex]
                        .tabManager.workspaces[workspaceIndex]
                        .panels[panelIndex]
                        .terminal,
                        terminal.hibernation != nil,
                        let kind = terminal.agent?.kind,
                        failedProviders.contains(kind.rawValue) else { continue }
                    terminal.agent = nil
                    terminal.hibernation = nil
                    terminal.resumeBinding = nil
                    terminal.wasAgentRunning = false
                    snapshot.windows[windowIndex]
                        .tabManager.workspaces[workspaceIndex]
                        .panels[panelIndex]
                        .terminal = terminal
                }
            }
        }
        return Set(failedProviders.compactMap(RestorableAgentKind.init(rawValue:)))
    }

    static func agentRegistrySnapshots(
        _ sources: [(kind: RestorableAgentKind, fileURL: URL)],
        fileManager: FileManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: CmuxAgentSessionRegistry.Snapshot]? {
        guard let firstSource = sources.first else {
            return nil
        }
        let registryURL: URL
        if let explicit = environment["CMUX_AGENT_SESSION_REGISTRY_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            registryURL = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath)
        } else {
            registryURL = firstSource.fileURL.deletingLastPathComponent()
                .appendingPathComponent(CmuxAgentSessionRegistry.filename, isDirectory: false)
        }
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let legacySources = sources.map {
            CmuxAgentSessionRegistry.LegacySource(provider: $0.kind.rawValue, url: $0.fileURL)
        }
        do {
            return try registry.snapshotsImportingLegacy(
                sources: legacySources,
                fileManager: fileManager
            )
        } catch {
            var recovered: [String: CmuxAgentSessionRegistry.Snapshot] = [:]
            for source in legacySources {
                recovered[source.provider] = (try? registry.snapshotImportingLegacy(
                    provider: source.provider,
                    legacyURL: source.url,
                    fileManager: fileManager
                )) ?? (try? registry.snapshot(provider: source.provider))
            }
            return recovered.isEmpty ? nil : recovered
        }
    }

    static func agentHookState(
        kind: RestorableAgentKind,
        fileURL: URL,
        snapshots: [String: CmuxAgentSessionRegistry.Snapshot]?,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> RestorableAgentHookSessionStoreFile? {
        if let snapshot = snapshots?[kind.rawValue],
           let state = try? RestorableAgentHookSessionStoreFile.decode(
               snapshot: snapshot,
               decoder: decoder
           ) {
            return state
        }
        return RestorableAgentHookSessionStoreFile.load(
            provider: kind.rawValue,
            legacyURL: fileURL,
            environment: ProcessInfo.processInfo.environment,
            fileManager: fileManager,
            decoder: decoder
        )
    }
}
