import Foundation

/// Aggregate over the agent rows of one workspace, shown in the accordion
/// header of `SidebarAgentStatusRows` (and standing in for the rows while
/// collapsed).
struct SidebarAgentStatusRowsSummary: Equatable {
    let agentCount: Int
    let needsInputCount: Int
    let runningCount: Int

    init(rows: [SidebarAgentStatusRow]) {
        agentCount = rows.count
        needsInputCount = rows.filter { $0.lifecycle == .needsInput }.count
        runningCount = rows.filter { $0.lifecycle == .running }.count
    }

    var text: String {
        var parts: [String] = []
        if agentCount == 1 {
            parts.append(String(localized: "sidebar.agentStatus.summary.oneAgent", defaultValue: "1 agent"))
        } else {
            parts.append(String(
                format: String(localized: "sidebar.agentStatus.summary.agentCount", defaultValue: "%lld agents"),
                agentCount
            ))
        }
        if needsInputCount == 1 {
            parts.append(String(localized: "sidebar.agentStatus.summary.oneNeedsInput", defaultValue: "1 needs input"))
        } else if needsInputCount > 1 {
            parts.append(String(
                format: String(localized: "sidebar.agentStatus.summary.needsInputCount", defaultValue: "%lld need input"),
                needsInputCount
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// Worst-state accent: needs-input beats running beats idle.
    var accentColorHex: String? {
        if needsInputCount > 0 { return "#FF9F0A" }
        if runningCount > 0 { return "#4C8DFF" }
        return nil
    }
}
