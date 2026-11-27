#if DEBUG
import Foundation

enum SessionSnapshotDebugBenchmark {
    @MainActor
    static func run(
        includeScrollback: Bool,
        persist: Bool,
        buildSnapshot: (Bool) -> AppSessionSnapshot?,
        persistedGeometryData: (AppSessionSnapshot?) -> Data?,
        persistSnapshot: (AppSessionSnapshot?, Data?) -> Void
    ) -> [String: Any] {
        let buildStart = ProcessInfo.processInfo.systemUptime
        let snapshot = buildSnapshot(includeScrollback)
        let buildMs = elapsedMs(since: buildStart)

        var persistMs: Double?
        if persist {
            let geometryData = persistedGeometryData(snapshot)
            let persistStart = ProcessInfo.processInfo.systemUptime
            persistSnapshot(snapshot, geometryData)
            persistMs = elapsedMs(since: persistStart)
        }

        return [
            "include_scrollback": includeScrollback,
            "persist": persist,
            "built": snapshot != nil,
            "saved": persist && snapshot != nil,
            "elapsed_ms": elapsedMs(since: buildStart),
            "build_ms": buildMs,
            "persist_ms": persistMs.map { $0 as Any } ?? NSNull(),
            "shape": snapshotShape(snapshot)
        ]
    }

    @MainActor
    static func seedScrollback(
        workspaces: [Workspace],
        charactersPerTerminal: Int
    ) -> [String: Any] {
        let targetCharacters = min(
            max(0, charactersPerTerminal),
            SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        )
        var workspaceCount = 0
        var terminalCount = 0
        var scrollbackCharacters = 0

        for workspace in workspaces {
            let seeded = workspace.debugSeedSessionSnapshotScrollback(
                charactersPerTerminal: targetCharacters
            )
            if seeded.terminals > 0 {
                workspaceCount += 1
                terminalCount += seeded.terminals
                scrollbackCharacters += seeded.characters
            }
        }

        return [
            "characters_per_terminal": targetCharacters,
            "workspaces": workspaceCount,
            "terminals": terminalCount,
            "scrollback_chars": scrollbackCharacters
        ]
    }

    private static func elapsedMs(since start: TimeInterval) -> Double {
        ((ProcessInfo.processInfo.systemUptime - start) * 1000.0 * 100.0).rounded() / 100.0
    }

    private static func snapshotShape(_ snapshot: AppSessionSnapshot?) -> [String: Any] {
        guard let snapshot else {
            return [
                "windows": 0,
                "workspaces": 0,
                "panels": 0,
                "terminals": 0,
                "browsers": 0,
                "markdown": 0,
                "scrollback_chars": 0,
                "status_entries": 0,
                "log_entries": 0,
                "progress_entries": 0,
                "git_entries": 0
            ]
        }

        var workspaces = 0
        var panels = 0
        var terminals = 0
        var browsers = 0
        var markdown = 0
        var scrollbackChars = 0
        var statusEntries = 0
        var logEntries = 0
        var progressEntries = 0
        var gitEntries = 0

        for window in snapshot.windows {
            workspaces += window.tabManager.workspaces.count
            for workspace in window.tabManager.workspaces {
                statusEntries += workspace.statusEntries.count
                logEntries += workspace.logEntries.count
                if workspace.progress != nil { progressEntries += 1 }
                if workspace.gitBranch != nil { gitEntries += 1 }
                panels += workspace.panels.count
                for panel in workspace.panels {
                    if let terminal = panel.terminal {
                        terminals += 1
                        scrollbackChars += terminal.scrollback?.count ?? 0
                    }
                    if panel.browser != nil { browsers += 1 }
                    if panel.markdown != nil { markdown += 1 }
                    if panel.gitBranch != nil { gitEntries += 1 }
                }
            }
        }

        return [
            "windows": snapshot.windows.count,
            "workspaces": workspaces,
            "panels": panels,
            "terminals": terminals,
            "browsers": browsers,
            "markdown": markdown,
            "scrollback_chars": scrollbackChars,
            "status_entries": statusEntries,
            "log_entries": logEntries,
            "progress_entries": progressEntries,
            "git_entries": gitEntries
        ]
    }
}
#endif
