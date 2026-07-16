import Foundation

/// PRDashboard fields that can be projected into sidebar badges.
public enum GHPRDisplayItem: String, CaseIterable, Codable, Sendable {
    case pr
    case title
    case ci
    case review
    case unresolved
    case jira
    case draft
    case conflicts
    case updated
    case author
    case pinned

    public static let defaultItems: [GHPRDisplayItem] = [.ci, .review, .unresolved, .jira]

    /// Parses the historical comma-separated setting while accepting the
    /// aliases supported by the original integration.
    public static func parse(_ text: String) -> [GHPRDisplayItem] {
        normalize(text.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
    }

    /// Normalizes aliases, removes unknown values, and preserves first-seen order.
    public static func normalize(_ values: [String]) -> [GHPRDisplayItem] {
        var seen = Set<GHPRDisplayItem>()
        return values.compactMap { raw in
            guard let item = normalized(raw), seen.insert(item).inserted else { return nil }
            return item
        }
    }

    private static func normalized(_ raw: String) -> GHPRDisplayItem? {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return switch key {
        case "pr", "pullrequest", "pull": .pr
        case "title", "prtitle": .title
        case "ci", "cistatus", "checks", "check": .ci
        case "review", "reviewstatus", "myreview", "changesrequested", "approval", "approvals": .review
        case "unresolved", "unresolvedcomments", "threads", "reviewthreads": .unresolved
        case "jira", "jiraticket", "ticket": .jira
        case "draft", "isdraft": .draft
        case "conflicts", "baseconflicts", "hasbaseconflicts": .conflicts
        case "updated", "updatedat": .updated
        case "author": .author
        case "pinned", "ispinned": .pinned
        default: nil
        }
    }
}
