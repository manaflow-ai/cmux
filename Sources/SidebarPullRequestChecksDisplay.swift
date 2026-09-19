import AppKit
import CmuxSidebar

/// Shared semantic presentation for the AppKit and SwiftUI PR glyphs.
struct SidebarPullRequestChecksDisplay {
    let checks: SidebarPullRequestChecks

    var iconName: String {
        if checks.mergeStatus == .conflict { return "exclamationmark.triangle.fill" }
        switch checks.status {
        case .success: return "checkmark"
        case .failure: return "xmark"
        case .pending: return "clock"
        case .neutral: return "minus.circle"
        case .unavailable: return "questionmark.circle"
        }
    }

    var tint: NSColor? {
        if checks.mergeStatus == .conflict { return .systemRed }
        switch checks.status {
        case .success: return .systemGreen
        case .failure: return .systemRed
        case .pending: return .systemOrange
        case .neutral, .unavailable: return nil
        }
    }

    var statusLabel: String {
        switch checks.status {
        case .success: return String(localized: "sidebar.pullRequest.checks.passing", defaultValue: "Checks passing")
        case .failure: return String(localized: "sidebar.pullRequest.checks.failing", defaultValue: "Checks failing")
        case .pending: return String(localized: "sidebar.pullRequest.checks.pending", defaultValue: "Checks pending")
        case .unavailable: return String(localized: "sidebar.pullRequest.checks.unavailable", defaultValue: "Checks unavailable")
        case .neutral:
            return checks.checks.isEmpty
                ? String(localized: "sidebar.pullRequest.checks.none", defaultValue: "No checks reported")
                : String(localized: "sidebar.pullRequest.checks.neutral", defaultValue: "Checks neutral or skipped")
        }
    }

    var mergeLabel: String {
        switch checks.mergeStatus {
        case .conflict: return String(localized: "sidebar.pullRequest.checks.mergeConflict", defaultValue: "Merge conflict")
        case .blocked: return String(localized: "sidebar.pullRequest.checks.blocked", defaultValue: "Merge blocked")
        case .ready: return String(localized: "sidebar.pullRequest.checks.noConflicts", defaultValue: "No merge conflicts")
        case .unknown: return String(localized: "sidebar.pullRequest.checks.mergeUnknown", defaultValue: "Mergeability unknown")
        }
    }

    var tooltip: String {
        let ordered = checks.checks.sorted {
            let lhs = priority($0.status), rhs = priority($1.status)
            return lhs == rhs ? $0.name < $1.name : lhs < rhs
        }
        var lines = [statusLabel, mergeLabel]
        // Native tooltips must fit on screen. Keep failures first and leave
        // the existing PR link as the route to the full check list.
        for check in ordered.prefix(20) {
            let marker: String
            switch check.status {
            case .success: marker = "✓"
            case .failure: marker = "×"
            case .pending: marker = "…"
            case .neutral: marker = "–"
            case .unavailable: marker = "?"
            }
            lines.append("\(marker) \(check.name)")
        }
        if ordered.count > 20 {
            lines.append(String(localized: "sidebar.pullRequest.checks.more", defaultValue: "Open the pull request for all checks."))
        }
        return lines.joined(separator: "\n")
    }

    private func priority(_ status: SidebarPullRequestCheckStatus) -> Int {
        switch status {
        case .failure: return 0
        case .pending: return 1
        case .unavailable: return 2
        case .neutral: return 3
        case .success: return 4
        }
    }
}
