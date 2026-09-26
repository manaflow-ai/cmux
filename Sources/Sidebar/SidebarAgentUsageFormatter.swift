import CmuxSidebar
import Foundation

/// Formats coding-agent usage for the sidebar and appends it to the matching
/// agent status entry, e.g. `Running · Opus 4.8 · 42% · ~$1.20`.
///
/// The percentage is the share of the model's context window in use; the
/// dollar figure is an estimate at published API list prices and is always
/// prefixed with the localized "estimated" marker.
struct SidebarAgentUsageFormatter {
    /// Separator between the status text and each usage component.
    static let separator = " · "

    let locale: Locale

    /// Creates a formatter.
    /// - Parameter locale: Locale for the percent and currency formats.
    init(locale: Locale = .current) {
        self.locale = locale
    }

    /// The compact usage summary, e.g. `Opus 4.8 · 42% · ~$1.20`.
    ///
    /// Components that are unknown (context window, price) are omitted.
    func summary(for usage: SidebarAgentUsage) -> String {
        var parts = [usage.modelName]
        if let fraction = usage.contextFraction {
            parts.append(fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
        }
        if let cost = usage.estimatedCostUSD {
            let costText = cost.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
            // The tilde marks the figure as an estimate, not a bill.
            parts.append(String(localized: "sidebar.agentUsage.estimatedCost", defaultValue: "~\(costText)"))
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
            return SidebarStatusEntry(
                key: entry.key,
                value: entry.value + Self.separator + summary(for: usage),
                icon: entry.icon,
                color: entry.color,
                url: entry.url,
                priority: entry.priority,
                format: entry.format,
                timestamp: entry.timestamp
            )
        }
    }
}
