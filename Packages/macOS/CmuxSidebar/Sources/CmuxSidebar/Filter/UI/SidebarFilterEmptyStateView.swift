public import SwiftUI

/// What the workspace list shows when a filter matches nothing.
///
/// An empty list is ambiguous: it reads the same as "you have no workspaces".
/// This says which query came up empty and offers the way out, so clearing the
/// filter never requires remembering a shortcut.
public struct SidebarFilterEmptyStateView: View {
    /// The query that matched nothing.
    public let queryText: String
    /// The field the query was scoped to, if any.
    public let scopeField: SidebarFilterField?
    /// The sidebar's accent color.
    public let accent: Color
    /// Geometry, scaled to the sidebar's font size.
    public let metrics: SidebarFilterMetrics
    /// Clears the filter.
    public let onClear: () -> Void

    /// Creates the empty state.
    ///
    /// - Parameters:
    ///   - queryText: The text that matched nothing.
    ///   - scopeField: The field the query was scoped to, if any.
    ///   - accent: The sidebar accent color.
    ///   - metrics: Geometry for the current font scale.
    ///   - onClear: Called when the user chooses to clear the filter.
    public init(
        queryText: String,
        scopeField: SidebarFilterField? = nil,
        accent: Color,
        metrics: SidebarFilterMetrics = SidebarFilterMetrics(),
        onClear: @escaping () -> Void
    ) {
        self.queryText = queryText
        self.scopeField = scopeField
        self.accent = accent
        self.metrics = metrics
        self.onClear = onClear
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.system(size: 11 * metrics.fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Plain rather than `.link`: the link style paints AppKit's link
            // blue, which is a different blue from the sidebar accent sitting
            // right above it.
            Button(action: onClear) {
                Text(String(
                    localized: "sidebar.filter.empty.clear",
                    defaultValue: "Clear filter"
                ))
                .font(.system(size: 10.5 * metrics.fontScale, weight: .medium))
                .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, metrics.horizontalInset + metrics.fieldPadding)
        .padding(.vertical, 10)
        .accessibilityIdentifier("SidebarFilterEmptyState")
    }

    /// The query as it appears in the message, quoted so a query made of
    /// spaces or punctuation is still visible.
    private var quoted: String {
        "\u{201C}\(queryText)\u{201D}"
    }

    /// The message, naming the scope when the query was scoped so a fruitless
    /// `@` search does not look like the workspace simply is not there.
    private var headline: String {
        guard let scopeField else {
            return String(
                localized: "sidebar.filter.empty.unscoped",
                defaultValue: "No workspace matches \(quoted)"
            )
        }
        return String(
            localized: "sidebar.filter.empty.scoped",
            defaultValue: "No \(SidebarFilterScopeLabel.text(for: scopeField)) matches \(quoted)"
        )
    }
}
