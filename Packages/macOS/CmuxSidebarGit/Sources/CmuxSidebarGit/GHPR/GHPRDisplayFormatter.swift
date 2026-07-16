import Foundation

/// Converts PRDashboard snapshots into the compact badge contract used by the sidebar.
public struct GHPRDisplayFormatter: Sendable {
    private let displayItems: [GHPRDisplayItem]
    private let jiraBaseURL: String?

    public init(displayItems: [GHPRDisplayItem], jiraBaseURL: String?) {
        self.displayItems = displayItems.isEmpty ? GHPRDisplayItem.defaultItems : displayItems
        self.jiraBaseURL = jiraBaseURL
    }

    public func badges(for context: GHPRPullRequestContext) -> [GHPRBadge] {
        displayItems.compactMap { item in
            switch item {
            case .pr:
                guard let url = context.url else { return nil }
                return badge(.pr, "\(context.repository)#\(context.number)", "emoji:🔗", nil, url)
            case .title:
                guard !context.title.isEmpty else { return nil }
                return badge(.title, String(context.title.prefix(140)), "emoji:📝", nil, context.url)
            case .ci:
                guard let value = ciBadgeValue(context) else { return nil }
                return badge(.ci, value, ciIcon(context), ciColor(context), context.url)
            case .review:
                guard let value = reviewBadgeValue(context) else { return nil }
                return badge(.review, value, reviewIcon(context), reviewColor(context), context.url)
            case .unresolved:
                guard context.unresolvedCount > 0 else { return nil }
                return badge(.unresolved, "\(context.unresolvedCount)", "emoji:💬", "#ff9500", context.url)
            case .jira:
                guard let ticket = context.jiraTicket else { return nil }
                return badge(.jira, ticket, "text:§", "#5e5ce6", jiraURL(ticket: ticket))
            case .draft:
                guard context.isDraft else { return nil }
                return badge(.draft, "draft", "emoji:📋", "#8e8e93", context.url)
            case .conflicts:
                guard context.hasBaseConflicts else { return nil }
                return badge(.conflicts, "conflict", "emoji:⚠️", "#ff3b30", context.url)
            case .updated:
                guard !context.updatedAt.isEmpty else { return nil }
                return badge(.updated, context.updatedAt, "emoji:🕐", nil, context.url)
            case .author:
                guard context.author != "unknown" else { return nil }
                return badge(.author, context.author, "emoji:👤", nil, context.url)
            case .pinned:
                guard context.isPinned else { return nil }
                return badge(.pinned, "pinned", "emoji:📌", nil, context.url)
            }
        }
    }

    private func badge(
        _ kind: GHPRBadge.Kind,
        _ value: String,
        _ icon: String,
        _ colorHex: String?,
        _ url: URL?
    ) -> GHPRBadge {
        GHPRBadge(kind: kind, value: value, icon: icon, colorHex: colorHex, url: url)
    }

    private func ciBadgeValue(_ context: GHPRPullRequestContext) -> String? {
        let status = context.ciStatus?.lowercased()
        if context.checkFailureCount > 0 || status == "failure" { return "\(context.checkFailureCount)" }
        if context.ciIsRunning || context.checkPendingCount > 0 || status == "pending" {
            return "\(context.checkPendingCount)"
        }
        if context.checkSuccessCount > 0 { return "ok" }
        return nonEmpty(status)
    }

    private func reviewBadgeValue(_ context: GHPRPullRequestContext) -> String? {
        if let changesRequestedCount = context.changesRequestedCount, changesRequestedCount > 0 {
            return "\(changesRequestedCount)"
        }
        if context.approvalCount > 0 { return "\(context.approvalCount)" }
        return nonEmpty(context.myReviewStatus?.lowercased())
    }

    private func ciIcon(_ context: GHPRPullRequestContext) -> String {
        let status = context.ciStatus?.lowercased()
        if context.checkFailureCount > 0 || status == "failure" { return "emoji:❌" }
        if context.ciIsRunning || context.checkPendingCount > 0 || status == "pending" { return "emoji:⏳" }
        return "emoji:✅"
    }

    private func reviewIcon(_ context: GHPRPullRequestContext) -> String {
        if let count = context.changesRequestedCount, count > 0 { return "emoji:🟥" }
        if context.approvalCount > 0 { return "emoji:✔" }
        return "emoji:👀"
    }

    private func ciColor(_ context: GHPRPullRequestContext) -> String {
        let status = context.ciStatus?.lowercased()
        if context.checkFailureCount > 0 || status == "failure" { return "#ff3b30" }
        if context.ciIsRunning || context.checkPendingCount > 0 || status == "pending" { return "#ff9500" }
        return "#34c759"
    }

    private func reviewColor(_ context: GHPRPullRequestContext) -> String? {
        if let count = context.changesRequestedCount, count > 0 { return "#ff3b30" }
        return context.approvalCount > 0 ? "#34c759" : nil
    }

    private func jiraURL(ticket: String) -> URL? {
        guard let rawBase = nonEmpty(jiraBaseURL) else { return nil }
        let encodedTicket = ticket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticket
        let rawURL: String
        if rawBase.contains("{ticket}") {
            rawURL = rawBase.replacingOccurrences(of: "{ticket}", with: encodedTicket)
        } else {
            let trimmedBase = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmedBase.isEmpty else { return nil }
            rawURL = trimmedBase.hasSuffix("/browse")
                ? "\(trimmedBase)/\(encodedTicket)"
                : "\(trimmedBase)/browse/\(encodedTicket)"
        }
        return URL(string: rawURL)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
