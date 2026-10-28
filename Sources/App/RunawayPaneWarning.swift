import Foundation

/// Which terminal is running away and what it is using, shown to the user
/// before macOS's low-memory path can take cmux down.
struct RunawayPaneWarning: Equatable, Identifiable, Sendable {
    let key: PaneMemoryPaneKey
    let workspaceTitle: String
    let paneTitle: String
    let ttyDevice: Int64
    let command: String
    let processCount: Int
    let memoryBytes: Int64
    /// Whether the terminal has a job cmux can stop. False when the runaway
    /// runs in the shell's own process group, or after a stop found nothing
    /// to signal.
    var canStop: Bool
    /// The session root's PID and birth time distinguish TTY-device reuse.
    var sessionIdentifier: String? = nil

    var id: PaneMemoryPaneKey { key }
    var workspaceId: UUID { key.workspaceId }
    var panelId: UUID { key.panelId }

    /// "next dev in my-app", naming the terminal tab and its workspace.
    var locationText: String {
        let paneName = paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminalName = paneName.isEmpty
            ? String(localized: "runawayPaneWarning.unnamedTerminal", defaultValue: "Terminal")
            : paneName
        let workspaceName = workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceName.isEmpty else { return terminalName }
        return String.localizedStringWithFormat(
            String(localized: "runawayPaneWarning.location", defaultValue: "%1$@ in %2$@"),
            terminalName,
            workspaceName
        )
    }

    /// "next dev · Processes: 3,574 · Memory: 31 GB".
    var detailText: String {
        let processes = processCount.formatted()
        let memory = ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
        guard !command.isEmpty else {
            return String.localizedStringWithFormat(
                String(
                    localized: "runawayPaneWarning.detailWithoutCommand",
                    defaultValue: "Processes: %1$@ · Memory: %2$@"
                ),
                processes,
                memory
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "runawayPaneWarning.detail",
                defaultValue: "%1$@ · Processes: %2$@ · Memory: %3$@"
            ),
            command,
            processes,
            memory
        )
    }
}
