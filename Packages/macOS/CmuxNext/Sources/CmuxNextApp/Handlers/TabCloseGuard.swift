import AppKit
import CmuxNextDaemon
import CmuxNextSettings

/// The one question a user's tab close can ask (#17501, as classic #17430).
/// A closed terminal ends after the daemon's reap grace, so a close asks
/// only while a closing terminal is doing work: an agent at work in it
/// ("Claude is still working.", `app.warnBeforeClosingAgentSession`), else a
/// foreground program (`app.warnBeforeClosingTab`). Idle terminals, browser
/// tabs, New Tab pages and agent chats (their session keeps running in
/// acpmux) close at once, and the undo toast brings them back. Automation
/// never asks.
@MainActor
enum TabCloseGuard {
    enum Warning: Equatable {
        /// The agent working in a closing terminal (the first, if several).
        case agent(String)
        /// Foreground programs in the closing terminals, unique and sorted.
        case programs([String])
    }

    /// Runs `close` at once, or after the person confirms the question.
    static func close(_ tabs: [TabModel], on daemon: DaemonService, services: AppServices, window: NSWindow?,
                      close: @escaping @MainActor () -> Void) {
        let snapshot = services.settings?.snapshot
        let warnTab = snapshot?.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        let warnAgent = snapshot?.warnBeforeClosingAgentSession ?? CmuxConfigSnapshot.closeWarningFallback
        let terminals = tabs.filter { $0.kind == .pty && !$0.dead }
        guard CloseUndoToasts.isUserClose, window != nil, warnTab || warnAgent, !terminals.isEmpty else { return close() }
        let agents = terminals.compactMap(workingAgent)
        // A terminal with a working agent is that agent's question, never the program one.
        let others = terminals.filter { workingAgent($0) == nil }
        Task { @MainActor in
            let programs = warnTab ? await DestructiveConfirmation.runningPrograms(of: others, on: daemon) : []
            guard let warning = warning(agents: agents, programs: programs, warnTab: warnTab, warnAgent: warnAgent) else { return close() }
            DestructiveConfirmation.present(prompt(warning, closing: tabs), in: window, settings: services.settings) { if $0 { close() } }
        }
    }

    /// The question for these closing terminals, or nil to close at once.
    static func warning(agents: [String], programs: [String], warnTab: Bool, warnAgent: Bool) -> Warning? {
        if warnAgent, let agent = agents.first { return .agent(agent) }
        if warnTab, !programs.isEmpty { return .programs(programs) }
        return nil
    }

    static func prompt(_ warning: Warning, closing tabs: [TabModel]) -> DestructiveConfirmation.Prompt {
        let title = tabs.count == 1 ? ConfirmationStrings.closeTitle(tabs[0].title) : ConfirmationStrings.closeTabsTitle(tabs.count)
        switch warning {
        case .agent(let agent):
            return .init(title: title, body: ConfirmationStrings.agentStillWorking(agent),
                         button: ConfirmationStrings.close, suppresses: CmuxConfigSnapshot.warnBeforeClosingAgentSessionPath)
        case .programs(let programs):
            return .init(title: title,
                         body: ConfirmationStrings.closeTabBody(programs.joined(separator: ", ")),
                         button: ConfirmationStrings.close, suppresses: CmuxConfigSnapshot.warnBeforeClosingTabPath)
        }
    }

    /// The display name of an agent working (or waiting on a permission
    /// answer) in `tab`'s terminal, else nil.
    static func workingAgent(_ tab: TabModel) -> String? {
        guard let status = tab.agent, status.state == .working || status.state == .blocked else { return nil }
        return displayName(status.agent)
    }

    /// "claude" reads "Claude"; an unnamed agent reads "The agent".
    static func displayName(_ agent: String?) -> String {
        guard let agent, let first = agent.first else { return ConfirmationStrings.theAgent }
        return first.uppercased() + agent.dropFirst()
    }
}
