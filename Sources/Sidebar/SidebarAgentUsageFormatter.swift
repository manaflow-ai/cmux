import CmuxSidebar
import Foundation

/// Formats coding-agent usage for the sidebar and appends it to the matching
/// agent status entry, e.g. `Running · Opus 4.8 · 42% · ~$1.20`.
///
/// The percentage is the share of the model's context window in use; the
/// dollar figure is an estimate at published API list prices, prefixed with
/// the localized "estimated" marker, suffixed with `+` when some usage could
/// not be priced, and explained in the entry's tooltip.
struct SidebarAgentUsageFormatter {
    /// Separator between the status text and each usage component.
    static let separator = " · "

    let locale: Locale
    /// The components to show; the rest are left out.
    let shownParts: SidebarAgentUsage.Parts

    /// Creates a formatter.
    /// - Parameters:
    ///   - locale: Locale for the percent and currency formats.
    ///   - shownParts: The components to show.
    init(locale: Locale = .current, shownParts: SidebarAgentUsage.Parts = .all) {
        self.locale = locale
        self.shownParts = shownParts
    }

    /// Tooltip for an entry that shows an estimated cost (resolved once;
    /// the app language only changes across launches).
    static let costHelpText = String(
        localized: "sidebar.agentUsage.costHelp",
        defaultValue: "Cost is an API list-price estimate, not your subscription bill."
    )

    /// The compact usage summary, e.g. `Opus 4.8 · 42% · ~$1.20`.
    ///
    /// Components that are unknown (context window, price) or not in
    /// ``shownParts`` are omitted; with none left the summary is empty.
    func summary(for usage: SidebarAgentUsage) -> String {
        var parts: [String] = []
        if shownParts.contains(.model) {
            parts.append(usage.modelName)
        }
        if shownParts.contains(.context), let fraction = usage.contextFraction {
            parts.append(fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
        }
        if shownParts.contains(.cost), let cost = usage.estimatedCostUSD {
            let costText = cost.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
            // The tilde marks the figure as an estimate, the plus a lower bound.
            parts.append(usage.costIsLowerBound
                ? String(localized: "sidebar.agentUsage.estimatedCostAtLeast", defaultValue: "~\(costText)+")
                : String(localized: "sidebar.agentUsage.estimatedCost", defaultValue: "~\(costText)"))
        }
        return parts.joined(separator: Self.separator)
    }

    /// Appends usage to each status entry whose key has usage.
    ///
    /// - Parameters:
    ///   - entries: Status entries in display order.
    ///   - usageByStatusKey: Usage keyed by agent status key; pass an empty
    ///     dictionary when `sidebar.showAgentUsage` is off.
    /// - Returns: The entries, with matching values extended in place.
    func decorate(
        _ entries: [SidebarStatusEntry],
        usageByStatusKey: [String: SidebarAgentUsage]
    ) -> [SidebarStatusEntry] {
        guard !usageByStatusKey.isEmpty else { return entries }
        return entries.map { entry in
            guard let usage = usageByStatusKey[entry.key] else { return entry }
            let usageText = summary(for: usage)
            guard !usageText.isEmpty else { return entry }
            return SidebarStatusEntry(
                key: entry.key,
                value: entry.value + Self.separator + usageText,
                icon: entry.icon,
                color: entry.color,
                url: entry.url,
                priority: entry.priority,
                format: entry.format,
                timestamp: entry.timestamp,
                helpText: shownParts.contains(.cost) && usage.estimatedCostUSD != nil ? Self.costHelpText : entry.helpText
            )
        }
    }
}
