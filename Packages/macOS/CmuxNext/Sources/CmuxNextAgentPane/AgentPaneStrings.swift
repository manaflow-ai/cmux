import Foundation

/// User-facing text of the agent pane host. The page's own text is in the
/// TypeScript pane.
public enum AgentPaneStrings {
    /// Tab strip title of an agent tab before the page reports a session title.
    public static var tabTitle: String {
        String(localized: "agentPane.tab.title", defaultValue: "Agent", bundle: .module)
    }

    static var notFound: String {
        String(localized: "agentPane.error.notFound", defaultValue: "acpmux was not found. Install acpmux or use a build that bundles it.", bundle: .module)
    }

    static func daemonFailed(logPath: String) -> String {
        let format = String(localized: "agentPane.error.daemonFailed", defaultValue: "acpmux did not start. Its log is at %@.", bundle: .module)
        return String(format: format, logPath)
    }

    static var timedOut: String {
        String(localized: "agentPane.error.timedOut", defaultValue: "acpmux did not answer in time.", bundle: .module)
    }

    static func message(for error: any Error) -> String {
        switch error as? AgentPaneHostError {
        case .acpmuxNotFound: notFound
        case .daemonFailed(let logPath): daemonFailed(logPath: logPath)
        case .timedOut, nil: timedOut
        }
    }
}
