import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation

/// What #28436 needs when the line typed after a quick double Cmd-D does not show in the second pane: every pane's
/// screen (which terminal got the bytes, if any), how the creation hold ended, the second pane's view (its gate, its
/// key path, whether it has the keyboard) and the journal's key and attach records since the first Cmd-D.
@MainActor
extension SplitOfPendingSplitTests {
    /// The journal's last sequence number: the report lists only what came after it.
    static func journalMark() -> UInt64 {
        InputJournal.shared.configure(InputJournalPolicy(enabled: true, recordsCharacters: false))
        return InputJournal.shared.entries(last: 1).last?.seq ?? 0
    }

    static func missedLineReport(content: WorkspaceContentController, second: PaneController, window: NSWindow,
                                 services: AppServices, connection: DaemonConnection, since mark: UInt64) async -> String {
        var lines: [String] = []
        let coordinator = services.keyRouter.creationInputCoordinator
        lines.append("hold: last end \(String(describing: coordinator.lastHoldEnd(in: window))), holding now \(coordinator.isHolding(in: window))")
        lines.append("first responder \(String(describing: window.firstResponder)); focused pane \(String(describing: content.focusedPane?.paneKey)), second \(second.paneKey)")
        for (key, pane) in content.panes.sorted(by: { $0.key < $1.key }) {
            for tab in pane.pane.tabs where tab.kind == .pty {
                let entry = services.cache.existingTerminal(tab.id)
                var line = "pane \(key) tab \(tab.id) surface \(tab.surface.rawValue) terminal \(tab.terminalID?.rawValue ?? "-")"
                    + " provisional \(ProvisionalTab.isProvisional(surface: tab.surface))"
                if let entry {
                    let hasKeys = (window.firstResponder as? NSView).map { $0 === entry.session.surfaceView || $0.isDescendant(of: entry.session.view) } ?? false
                    line += " | view: gate \(entry.gate == nil ? "none" : "open") creating-id \(entry.io.creatingTerminalID ?? "-")"
                        + " focused \(entry.session.model.isFocused) has-keyboard \(hasKeys) in-window \(entry.session.view.window === window)"
                        + " in-second \(entry.session.view.isDescendant(of: second.view))"
                } else {
                    line += " | no view"
                }
                if !ProvisionalTab.isProvisional(surface: tab.surface) {
                    let screen = (try? await connection.request(ReadScreenRequest(surface: tab.surface), timeout: .seconds(5)))?.text
                    let shown = screen.map { $0.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.suffix(6).joined(separator: " / ") } ?? "(read-screen failed)"
                    line += " | screen: \(shown)"
                }
                lines.append(line)
            }
        }
        for record in InputJournal.shared.entries() where record.seq > mark {
            switch record.kind {
            case .key, .attach, .focus, .responder, .marker, .content, .keyboardGivenBack:
                lines.append("journal \(record.seq) +\(record.uptimeNanos / 1_000_000)ms \(record.kind)")
            default: continue
            }
        }
        return lines.joined(separator: "\n")
    }
}
