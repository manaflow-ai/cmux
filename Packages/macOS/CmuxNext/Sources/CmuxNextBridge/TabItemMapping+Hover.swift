public import CmuxNextDaemon
public import CmuxNextTabs
import Foundation

/// A tab's hover card facts (`TabHoverFacts`, Leo 2026-10-14): what kind of tab it is, what
/// it is doing and since when, from the records the strip already reads. An agent chat's
/// come from its acpmux session (`lane`, model, folder); a terminal's from its agent
/// detector, how long its command has run or, at its prompt, when it last printed, with its branch.
/// The strip's card reads them when it shows (`TabStripModel.hoverFacts`), never the strip's item.
extension TabItemMapping {
    public func hoverFacts(_ tab: TabModel, turns: AgentTurnStateStore = .shared) -> TabHoverFacts {
        var facts = TabHoverFacts()
        switch tab.kind {
        case .browser:
            facts.kind = .browser
        case .conversation:
            guard let ref = tab.agentSession else { return facts }
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
            } else if let prompt = tab.promptSinceMs {
                // Counted from when this client saw it when the daemon's clock runs ahead, as `commandStart`
                // does; with no output since the daemon started or adopted the terminal, from its prompt.
                func clamped(_ ms: UInt64, seen: Date?) -> UInt64 {
                    seen.map { min(ms, UInt64($0.timeIntervalSince1970 * 1000)) } ?? ms
                }
                let at = tab.lastOutputMs.map { clamped($0, seen: tab.lastOutputSeenAt) }
                    ?? clamped(prompt, seen: tab.promptSeenAt)
                facts.lastOutput = SidebarMapping.date(ms: at)
            }
        case .remoteTerminal, .other:
            break
        }
        return facts
    }

    /// An agent chat's folder (its acpmux session's), its strip subtitle; nil for any other tab.
    func conversationFolder(_ tab: TabModel, turns: AgentTurnStateStore) -> String? {
        guard tab.kind == .conversation, let ref = tab.agentSession else { return nil }
        return turns.detail(for: ref)?.cwd.map(SidebarMapping.shared.abbreviate)
    }
}
