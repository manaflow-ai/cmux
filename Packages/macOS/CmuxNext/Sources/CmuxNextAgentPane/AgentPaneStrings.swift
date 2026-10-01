import Foundation

// User-facing text of the agent pane host. The page's own text is in the
// TypeScript pane.

extension AgentPaneModel {
    /// Tab strip title of an agent tab before the page reports a session title.
    public static var tabTitle: String {
        String(localized: "agentPane.tab.title", defaultValue: "Agent", bundle: .module)
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
        case .timedOut, nil:
            String(localized: "agentPane.error.timedOut", defaultValue: "acpmux did not answer in time.", bundle: .module)
        }
    }
}
