public import Foundation

extension TabItem {
    /// A subagent pane's tab says its subagent's state (`running`, `completed`, `failed` or
    /// `cancelled`), since when and model in its hover card and spinner, in place of its chat's: the
    /// pane is a tab on its chat's session (SubagentTabFacts). A finished subagent's tab never spins
    /// or reads "Working" while its chat works. `spins`: the setting that shows agents working on tabs.
    public mutating func showSubagent(state: String, since: Date?, model: String?, spins: Bool) {
        hover.activity = switch state {
        case "running": .working
        case "completed": .done
        case "failed": .failed
        default: .idle
        }
        hover.since = since
        hover.model = model
        if state == "running" {
            if spins, !indicator.isWorking { indicator = .working(progress: nil) }
        } else if indicator.isWorking {
            indicator = .idle
        }
    }
}
