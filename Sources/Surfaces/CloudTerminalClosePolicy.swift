import CmuxSettings
import Foundation

/// What the person chose when closing a pane that shows a cloud terminal.
enum CloudTerminalCloseDecision: Equatable, Sendable {
    /// Close the pane; the terminal keeps running on its machine.
    case detach
    /// End the terminal's process on its machine, then close the pane.
    case kill
    /// Leave the pane open.
    case cancel
}

/// Pure decision logic for closing a cloud terminal pane (Cmd+W, the tab close
/// button, the pane close button). The pane is only a projection of a terminal
/// that lives in the machine's cmux-tui session, so "close" has to say whether
/// the terminal survives. `app.closeCloudTerminal` decides; `ask` prompts.
enum CloudTerminalClosePolicy {
    enum Resolution: Equatable, Sendable {
        case detach
        case kill
        case prompt
    }

    static func resolution(for action: CloudTerminalCloseAction) -> Resolution {
        switch action {
        case .ask: return .prompt
        case .detach: return .detach
        case .kill: return .kill
        }
    }

    /// The action "Remember my choice" persists. Cancelling never persists,
    /// and an unchecked box changes nothing.
    static func actionToRemember(decision: CloudTerminalCloseDecision, remember: Bool) -> CloudTerminalCloseAction? {
        guard remember else { return nil }
        switch decision {
        case .detach: return .detach
        case .kill: return .kill
        case .cancel: return nil
        }
    }

    /// Prompt buttons in `NSAlert` order: Detach (default), Kill Process, Cancel.
    static func decision(forButtonIndex index: Int) -> CloudTerminalCloseDecision {
        switch index {
        case 0: return .detach
        case 1: return .kill
        default: return .cancel
        }
    }
}

/// Copy for the close prompt: one terminal names it, a pane close counts them.
struct CloudTerminalClosePrompt: Equatable, Sendable {
    let title: String
    let message: String

    init(terminalNames: [String], machineName: String) {
        let names = terminalNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if names.count <= 1 {
            let name = names.first ?? String(localized: "dialog.closeCloudTerminal.unnamed", defaultValue: "terminal")
            title = String(
                format: String(localized: "dialog.closeCloudTerminal.title", defaultValue: "Close cloud terminal \u{201C}%@\u{201D}?"),
                locale: .current,
                name
            )
            message = String(
                format: String(
                    localized: "dialog.closeCloudTerminal.message",
                    defaultValue: "Detach keeps it running on %@; reopen it from the Cloud sidebar. Kill Process ends it on the machine."
                ),
                locale: .current,
                machineName
            )
        } else {
            title = String(
                format: String(localized: "dialog.closeCloudTerminals.title", defaultValue: "Close %lld cloud terminals?"),
                locale: .current,
                Int64(names.count)
            )
            message = String(
                format: String(
                    localized: "dialog.closeCloudTerminals.message",
                    defaultValue: "Detach keeps them running on %@; reopen them from the Cloud sidebar. Kill Process ends them on the machine."
                ),
                locale: .current,
                machineName
            )
        }
    }
}
