import AppKit
import Foundation

// User-facing text of the agent pane host. The page's own text is in the
// TypeScript pane.

extension AgentPaneModel {
    /// Tab strip title of an agent tab before the page reports a session title.
    public static var tabTitle: String {
        String(localized: "agentPane.tab.title", defaultValue: "Agent", bundle: .module)
    }
}

extension AgentPaneView {
    /// Shown when the pane's page keeps crashing and no longer reloads itself.
    static var crashedMessage: String {
        String(localized: "agentPane.crashed.message", defaultValue: "The agent pane crashed repeatedly.", bundle: .module)
    }

    /// Title of the save panel for the ACP inspector's exported log.
    static var saveLogTitle: String {
        String(localized: "agentPane.inspector.saveLog", defaultValue: "Save ACP Log", bundle: .module)
    }

    static var reloadTitle: String {
        String(localized: "agentPane.crashed.reload", defaultValue: "Reload", bundle: .module)
    }
}

extension AgentPaneHostError {
    /// What the page shows for `error`; anything but a host error reads as a
    /// timeout.
    static func userMessage(for error: any Error) -> String {
        switch error as? AgentPaneHostError {
        case .acpmuxNotFound:
            String(localized: "agentPane.error.notFound", defaultValue: "acpmux was not found. Install acpmux or use a build that bundles it.", bundle: .module)
        case .daemonFailed(let logPath):
            String(format: String(localized: "agentPane.error.daemonFailed", defaultValue: "acpmux did not start. Its log is at %@.", bundle: .module), logPath)
        case .daemonStopped:
            String(localized: "agentPane.error.daemonStopped", defaultValue: "acpmux is not running. Open a new agent chat to start it.", bundle: .module)
        case .timedOut, nil:
            String(localized: "agentPane.error.timedOut", defaultValue: "acpmux did not answer in time.", bundle: .module)
        }
    }
}
