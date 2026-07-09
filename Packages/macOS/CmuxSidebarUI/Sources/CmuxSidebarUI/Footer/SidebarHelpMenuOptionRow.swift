public import CoreGraphics
public import SwiftUI

/// A single row in the sidebar help-menu popover.
///
/// Lays out, left to right: the option title, a flexible spacer, an optional
/// monospaced keyboard-shortcut hint, an optional trailing SF Symbol, and, for
/// external links, a small up-right arrow glyph. The whole row is a plain button
/// whose press invokes the caller's `action`. Title, hint, icon, the
/// external-link flag, the accessibility identifier, and the action are all
/// supplied as values/closures, so this package view holds no app-target
/// dependency.
public struct SidebarHelpMenuOptionRow: View {
    let title: String
    let isExternalLink: Bool
    let shortcutHint: String?
    let trailingSystemImage: String?
    let accessibilityIdentifier: String
    let action: () -> Void

    /// Creates a help-menu option row.
    /// - Parameters:
    ///   - title: The displayed option label.
    ///   - isExternalLink: Whether to show the trailing up-right arrow glyph
    ///     that marks an option opening an external URL.
    ///   - shortcutHint: Optional keyboard-shortcut hint shown before any
    ///     trailing icon; hidden when `nil`.
    ///   - trailingSystemImage: Optional trailing SF Symbol shown after the
    ///     shortcut hint; hidden when `nil`.
    ///   - accessibilityIdentifier: Accessibility identifier for the row button.
    ///   - action: Invoked when the row is pressed.
    public init(
        title: String,
        isExternalLink: Bool,
        shortcutHint: String? = nil,
        trailingSystemImage: String? = nil,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isExternalLink = isExternalLink
        self.shortcutHint = shortcutHint
        self.trailingSystemImage = trailingSystemImage
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
                if let shortcutHint {
                    Self.shortcutHintLabel(text: shortcutHint)
                }
                if let trailingSystemImage {
                    Self.trailingIcon(systemName: trailingSystemImage)
                }
                if isExternalLink {
                    Self.trailingIcon(systemName: "arrow.up.right", size: 8)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private static func shortcutHintLabel(text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 10, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }

    @ViewBuilder
    private static func trailingIcon(systemName: String, size: CGFloat = 13) -> some View {
        Image(systemName: systemName)
            .cmuxSymbolRasterSize(size)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }
}
