public import Foundation

/// Formats coding-agent usage for the sidebar and appends it to the matching
/// agent status entry, e.g. `Running · Opus 4.8 · 42% · ~$1.20`.
///
/// The percentage is the share of the model's context window in use; the
/// dollar figure is an estimate at published API list prices, marked by the
/// localized ``Strings`` the app supplies and explained in the entry's tooltip.
public struct SidebarAgentUsageFormatter: Sendable {
    /// Localized text the app supplies from its string catalog.
    public struct Strings: Sendable {
        /// Marks a formatted cost as an estimate, e.g. `$1.20` → `~$1.20`.
        public let estimatedCost: @Sendable (String) -> String
        /// Marks a formatted cost as an estimate that is a lower bound
        /// because some usage could not be priced, e.g. `$1.20` → `~$1.20+`.
        public let estimatedCostAtLeast: @Sendable (String) -> String
        /// Tooltip for an entry that shows an estimated cost.
        public let costHelpText: String

        /// Creates the formatter's localized text.
        /// - Parameters:
        ///   - estimatedCost: Marks a formatted cost as an estimate.
        ///   - estimatedCostAtLeast: Marks a formatted cost as an estimate
        ///     and a lower bound.
        ///   - costHelpText: Tooltip for an entry that shows a cost.
        public init(
            estimatedCost: @escaping @Sendable (String) -> String,
            estimatedCostAtLeast: @escaping @Sendable (String) -> String,
            costHelpText: String
        ) {
            self.estimatedCost = estimatedCost
            self.estimatedCostAtLeast = estimatedCostAtLeast
            self.costHelpText = costHelpText
        }
    }

    /// Separator between the status text and each usage component.
    public static let separator = " · "

    let strings: Strings
    let locale: Locale
    /// The components to show; the rest are left out.
    let shownParts: SidebarAgentUsage.Parts

    /// Creates a formatter.
    /// - Parameters:
    ///   - strings: The localized cost marks and tooltip.
    ///   - locale: Locale for the percent and currency formats.
    ///   - shownParts: The components to show.
    public init(strings: Strings, locale: Locale = .current, shownParts: SidebarAgentUsage.Parts = .all) {
        self.strings = strings
        self.locale = locale
        self.shownParts = shownParts
    }

    /// The compact usage summary, e.g. `Opus 4.8 · 42% · ~$1.20`.
    ///
    /// Components that are unknown (context window, price) or not in
    /// `shownParts` are omitted; with none left the summary is empty.
    public func summary(for usage: SidebarAgentUsage) -> String {
        var parts: [String] = []
        if shownParts.contains(.model) {
            parts.append(usage.modelName)
        }
        if shownParts.contains(.context), let fraction = usage.contextFraction {
            parts.append(fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
        }
        if shownParts.contains(.cost), let cost = usage.estimatedCostUSD {
            let costText = cost.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
            parts.append(usage.costIsLowerBound ? strings.estimatedCostAtLeast(costText) : strings.estimatedCost(costText))
        }
        return parts.joined(separator: Self.separator)
    }

    /// Appends usage to each status entry whose key has usage.
    ///
    /// An entry whose summary comes out empty is returned unchanged. When the
    /// summary shows a cost, ``Strings/costHelpText`` replaces the entry's
    /// tooltip; every other field is kept.
    ///
    /// - Parameters:
    ///   - entries: Status entries in display order.
    ///   - usageByStatusKey: Usage keyed by agent status key; pass an empty
    ///     dictionary when `sidebar.showAgentUsage` is off.
    /// - Returns: The entries, with matching values extended in place.
    public func decorate(
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
                helpText: shownParts.contains(.cost) && usage.estimatedCostUSD != nil ? strings.costHelpText : entry.helpText,
                workState: entry.workState
            )
        }
    }
}
