public import CmuxSettings
// CmuxFoundation vends the shared `Image.cmuxSymbolRasterSize` helper used by the
// checkmark glyph; internal import since the helper is only used inside `body`.
internal import CmuxFoundation
public import SwiftUI

/// Popover content listing the selectable browser theme modes.
///
/// Pure presentation: the app builds a `[BrowserThemeModeItem]` snapshot with
/// app-resolved localized names, passes the current `selectedMode`, and supplies
/// `onSelect` to commit a choice. The popover-presentation `@State` stays at the
/// app call site; this view renders only the menu content. Dismissal-on-select
/// is the app's responsibility inside `onSelect`.
public struct BrowserThemeModePopoverView: View {
    private let items: [BrowserThemeModeItem]
    private let selectedMode: BrowserThemeMode
    private let onSelect: (BrowserThemeMode) -> Void

    /// Creates the theme-mode popover content.
    /// - Parameters:
    ///   - items: One snapshot per selectable mode, with app-localized names.
    ///   - selectedMode: The currently active mode, shown with a checkmark.
    ///   - onSelect: Invoked with the chosen mode when a row is tapped.
    public init(
        items: [BrowserThemeModeItem],
        selectedMode: BrowserThemeMode,
        onSelect: @escaping (BrowserThemeMode) -> Void
    ) {
        self.items = items
        self.selectedMode = selectedMode
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                Button {
                    onSelect(item.mode)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.mode == selectedMode ? "checkmark" : "circle")
                            .cmuxSymbolRasterSize(10, weight: .semibold)
                            .opacity(item.mode == selectedMode ? 1.0 : 0.0)
                            .frame(width: 12, alignment: .center)
                        Text(item.displayName)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(item.mode == selectedMode ? Color.primary.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserThemeModeOption\(item.mode.rawValue.capitalized)")
            }
        }
        .padding(8)
        .frame(minWidth: 128)
    }
}
