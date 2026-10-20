import CmuxFoundation
import SwiftUI

/// A search field in the workspace titlebar, like the VS Code command center.
/// It only looks like a field: clicking it opens Go to File for the focused workspace.
struct TitlebarFileSearchField: View {
    let textColor: Color
    let action: () -> Void

    @State private var isHovered = false
    @State private var shortcutHint = Self.currentShortcutHint()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                Text(String(localized: "titlebar.fileSearch.placeholder", defaultValue: "Search files"))
                    .cmuxFont(size: 12)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let shortcutHint {
                    Text(shortcutHint)
                        .cmuxFont(size: 11)
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            .foregroundColor(textColor.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(textColor.opacity(isHovered ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(textColor.opacity(0.12))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(String(localized: "commandPalette.goToFile.title", defaultValue: "Go to File…"))
        .accessibilityLabel(String(localized: "commandPalette.goToFile.title", defaultValue: "Go to File…"))
        .accessibilityIdentifier("TitlebarFileSearchField")
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            shortcutHint = Self.currentShortcutHint()
        }
    }

    private static func currentShortcutHint() -> String? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .goToFile)
        return shortcut.isUnbound ? nil : shortcut.displayString
    }
}

/// Sizing for ``TitlebarFileSearchField`` within the titlebar area over the workspace content.
enum TitlebarFileSearchFieldLayout {
    static let maximumWidth: CGFloat = 360
    static let minimumWidth: CGFloat = 180
    /// Share of the area the field may take, leaving room for the leading workspace title.
    static let maximumShareOfRegion: CGFloat = 0.4

    /// Gap kept between the workspace title and the field.
    static let titleGap: CGFloat = 8

    /// The part of the titlebar the field centers in: right of the window controls and
    /// sidebar, where the workspace title starts (`titleLeadingPadding` includes the
    /// title's own 12 point inset), minus anything reserved before the title.
    static func region(
        titlebarWidth: CGFloat,
        titleLeadingPadding: CGFloat,
        reservedLeadingWidth: CGFloat = 0
    ) -> (leading: CGFloat, width: CGFloat) {
        let leading = max(0, titleLeadingPadding + reservedLeadingWidth - 12)
        return (leading, max(0, titlebarWidth - leading))
    }

    /// The field's width when centered in a titlebar region `regionWidth` points wide,
    /// or `nil` when the region is too narrow to show it beside the title.
    static func width(regionWidth: CGFloat) -> CGFloat? {
        let width = min(maximumWidth, regionWidth * maximumShareOfRegion)
        return width >= minimumWidth ? width : nil
    }

    /// Trailing padding for the title row so the title truncates before the centered field.
    static func titleTrailingPadding(regionWidth: CGFloat, fieldWidth: CGFloat?) -> CGFloat {
        guard let fieldWidth else { return titleGap }
        return (regionWidth + fieldWidth) / 2 + titleGap
    }
}
