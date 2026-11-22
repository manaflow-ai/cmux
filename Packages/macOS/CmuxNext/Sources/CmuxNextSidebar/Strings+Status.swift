import Foundation

extension Strings {
    /// Group by Status's header names (`SidebarStatusSection`): the Priority view's own words for its states.
    static func statusSection(_ section: SidebarStatusSection) -> String {
        switch section {
        case .needsYou: priorityNeedsYou
        case .done: priorityDone
        case .failed: priorityFailed
        case .ciFailing: priorityCIFailing
        case .working: priorityWorking
        case .idle: priorityIdle
        }
    }

    /// A row's status pill (`experiments.agentBadges`, `SidebarAgentPill`), in Leo's words, sentence case. Done is the
    /// Priority view's own word.
    static var agentPillRunning: String {
        String(localized: "sidebar.agentPill.running", defaultValue: "Running", bundle: .localizedModule)
    }
    static var agentPillNeedsApproval: String {
        String(localized: "sidebar.agentPill.needsApproval", defaultValue: "Needs approval", bundle: .localizedModule)
    }
}
