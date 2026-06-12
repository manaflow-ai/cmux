import CmuxControlSocket
import Foundation

/// The live-app half of the terminal history-panel v1 reporting commands.
extension TerminalController {
    func controlSidebarRecordCommandHistory(tabArg: String?, panelArg: String?, command: String) -> ControlSidebarPanelWriteResolution {
        controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: true,
            requireLiveSurface: true
        ) { tab, surfaceId in
            let cwd = tab.panelDirectories[surfaceId]
            let recorded = TerminalCommandHistoryStore.shared.record(
                workspaceId: tab.id,
                panelId: surfaceId,
                command: command,
                cwd: cwd,
                shell: nil
            )
#if DEBUG
            cmuxDebugLog(
                "history.record workspace=\(tab.id.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                    "recorded=\(recorded ? 1 : 0) commandLen=\(command.count)"
            )
#endif
        }
    }

    func controlSidebarReplaceCommandHistorySnapshot(
        tabArg: String?,
        panelArg: String?,
        shell: String?,
        snapshot: String
    ) -> ControlSidebarPanelWriteResolution {
        let snapshotEntries = Self.parseControlSidebarCommandHistorySnapshotEntries(snapshot)
        return controlSidebarResolvePanelWrite(
            tabArg: tabArg,
            panelArg: panelArg,
            prune: true,
            requireLiveSurface: true
        ) { tab, surfaceId in
            TerminalCommandHistoryStore.shared.replaceShellHistorySnapshot(
                workspaceId: tab.id,
                panelId: surfaceId,
                entries: snapshotEntries,
                shell: shell
            )
#if DEBUG
            cmuxDebugLog(
                "history.snapshot workspace=\(tab.id.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                    "commands=\(snapshotEntries.count) shell=\(shell ?? "")"
            )
#endif
        }
    }

    private static func parseControlSidebarCommandHistorySnapshotEntries(_ snapshot: String) -> [TerminalCommandHistorySnapshotEntry] {
        snapshot
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine in
                let line = String(rawLine)
                if let tabIndex = line.firstIndex(of: "\t") {
                    let timestampText = String(line[..<tabIndex])
                    let command = String(line[line.index(after: tabIndex)...])
                    if let timestamp = Double(timestampText),
                       !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return TerminalCommandHistorySnapshotEntry(
                            command: command,
                            startedAt: Date(timeIntervalSince1970: timestamp)
                        )
                    }
                }
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return TerminalCommandHistorySnapshotEntry(command: line)
            }
    }
}
