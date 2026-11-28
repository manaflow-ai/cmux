import CmuxNextDaemon
import CmuxNextTabs
import Foundation

/// A tab's hover card facts (`TabHoverFacts`, Leo 2026-10-14): what kind of tab it is, what
/// it is doing and since when, from the records the strip already reads. An agent chat's
/// come from its acpmux session (`lane`, model, folder); a terminal's from its agent
/// detector or how long its command has run, with its branch.
extension TabItemMapping {
    func hoverFacts(_ tab: TabModel, turns: AgentTurnStateStore) -> (facts: TabHoverFacts, folder: String?) {
        var facts = TabHoverFacts()
        switch tab.kind {
        case .browser:
            facts.kind = .browser
        case .conversation:
            guard let ref = tab.agentSession else { return (facts, nil) }
            facts.kind = .agentChat
            let detail = turns.detail(for: ref)
            facts.model = detail?.model
            facts.activity = switch detail?.laneState {
            case "working"?: .working
            case "input"?: .needsInput
            case "idle"?: .idle
            case "failed"?, "lost"?: .failed
            default: nil
            }
            facts.since = detail?.laneSinceMs.map(SidebarMapping.date(ms:))
            return (facts, detail?.cwd.map(SidebarMapping.shared.abbreviate))
        case .pty:
            facts.kind = .terminal
            facts.branch = tab.gitBranch.flatMap { $0.isEmpty || tab.gitDetached ? nil : $0 }
            if let agent = tab.agent {
                facts.activity = switch agent.state {
                case .working: .working
                case .blocked: .needsInput
                case .idle, .done: .idle
                case .unknown: nil
                }
                facts.since = agent.sinceMs.map(SidebarMapping.date(ms:))
            } else if let since = SidebarMapping.commandStart(tab) {
                facts.activity = .running
                facts.since = SidebarMapping.date(ms: since)
            }
        case .remoteTerminal, .other:
            break
        }
        return (facts, nil)
    }
}
