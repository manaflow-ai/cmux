import Foundation
import CmuxPanes

extension Workspace {
    /// The workspace's terminal panels for AppleScript enumeration: sidebar
    /// order first (deduplicated), then any remaining terminal panels sorted by
    /// stable id. Drives the `terminals` element of the scripting bridge.
    func scriptingTerminalPanels() -> [TerminalPanel] {
        var results: [TerminalPanel] = []
        var seen: Set<UUID> = []

        for panelId in sidebarOrderedPanelIds() {
            guard seen.insert(panelId).inserted,
                  let terminal = terminalPanel(for: panelId) else {
                continue
            }
            results.append(terminal)
        }

        let remaining = panels.values
            .compactMap { $0 as? TerminalPanel }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        for terminal in remaining where seen.insert(terminal.id).inserted {
            results.append(terminal)
        }

        return results
    }
}
