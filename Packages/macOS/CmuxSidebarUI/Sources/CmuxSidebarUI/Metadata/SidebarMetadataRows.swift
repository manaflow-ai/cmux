public import CmuxSidebar
public import SwiftUI

/// Renders a workspace's keyed status entries in the sidebar, collapsed to the
/// first few rows with a "Show more"/"Show less" toggle past the limit.
public struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let activeForegroundColor: Color
    let activeSecondaryForegroundColor: Color
    let fontScale: CGFloat
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    /// Creates the status-entry list.
    /// - Parameters:
    ///   - entries: The status entries to display, in render order.
    ///   - isActive: Whether the owning workspace row is the active selection.
    ///   - activeForegroundColor: Foreground color used when active.
    ///   - activeSecondaryForegroundColor: Secondary foreground used when active.
    ///   - fontScale: Multiplier applied to the base font size.
    ///   - onFocus: Invoked when a row is tapped or the toggle is pressed.
    public init(
        entries: [SidebarStatusEntry],
        isActive: Bool,
        activeForegroundColor: Color,
        activeSecondaryForegroundColor: Color,
        fontScale: CGFloat,
        onFocus: @escaping () -> Void
    ) {
        self.entries = entries
        self.isActive = isActive
        self.activeForegroundColor = activeForegroundColor
        self.activeSecondaryForegroundColor = activeSecondaryForegroundColor
        self.fontScale = fontScale
        self.onFocus = onFocus
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(
                    entry: entry,
                    isActive: isActive,
                    activeForegroundColor: activeForegroundColor,
                    fontScale: fontScale,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less", bundle: .main) : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more", bundle: .main)) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10 * fontScale, weight: .semibold))
                .foregroundColor(isActive ? activeSecondaryForegroundColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
    }

    private var visibleEntries: [SidebarStatusEntry] {
        guard !isExpanded, entries.count > collapsedEntryLimit else { return entries }
        return Array(entries.prefix(collapsedEntryLimit))
    }

    private var helpText: String {
        entries.map { entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.key : trimmed
        }
        .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > collapsedEntryLimit
    }
}
