import CMUXAgentLaunch
import Foundation

extension AppDelegate {
    nonisolated static func feedWorkstreamTitle(for event: WorkstreamEvent) -> String? {
        switch event.hookEventName {
        case .preCompact, .postCompact:
            return String(localized: "feed.lifecycle.compaction.title", defaultValue: "Compaction")
        case .subagentStart, .subagentStop:
            return String(localized: "feed.lifecycle.subagent.title", defaultValue: "Subagent")
        default:
            return nil
        }
    }
}
