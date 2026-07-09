public import SwiftUI
private import CmuxAppKitSupportUI

/// The sidebar footer help button and its popover menu.
///
/// Renders the question-mark ``SidebarFooterIconButton`` that toggles an
/// ``ArrowlessPopoverAnchor`` popover listing the help options (welcome, send
/// feedback, keyboard shortcuts, import browser data, docs, changelog, GitHub,
/// GitHub issues, Discord, check for updates). Every row's title is supplied by
/// the caller as a localized string and every row's effect is supplied as a
/// closure; the external-link rows are gated by whether the caller passed a
/// matching option. This keeps the package view pure presentation: it owns only
/// the popover-presentation state, performs no app-target work, and never calls
/// `String(localized:)` itself (which would bind to the package bundle and drop
/// non-English translations). The send-feedback keyboard-shortcut hint is also a
/// value snapshot, so the view holds no observable dependency.
public struct SidebarHelpMenuButton: View {
    /// One row in the help popover: its localized title, accessibility id, the
    /// external-link affordance, and the effect to run when chosen.
    public struct Option: Identifiable {
        /// Stable identity for the row within the menu.
        public let id: String
        let title: String
        let isExternalLink: Bool
        let shortcutHint: String?
        let trailingSystemImage: String?
        let action: () -> Void

        /// Creates a help-menu option.
        /// - Parameters:
        ///   - id: Stable identity, reused as the row's accessibility identifier.
        ///   - title: Localized row label (resolved app-side).
        ///   - isExternalLink: Whether to show the external-link arrow glyph.
        ///   - shortcutHint: Optional keyboard-shortcut display string.
        ///   - trailingSystemImage: Optional trailing SF Symbol name.
        ///   - action: Invoked when the row is chosen (after the popover closes).
        public init(
            id: String,
            title: String,
            isExternalLink: Bool,
            shortcutHint: String? = nil,
            trailingSystemImage: String? = nil,
            action: @escaping () -> Void
        ) {
            self.id = id
            self.title = title
            self.isExternalLink = isExternalLink
            self.shortcutHint = shortcutHint
            self.trailingSystemImage = trailingSystemImage
            self.action = action
        }
    }

    private let buttonSize: CGFloat = 22
    private let iconSize: CGFloat = 11

    private let helpTitle: String
    private let options: [Option]

    @State private var isPopoverPresented = false

    /// Creates the sidebar help button.
    /// - Parameters:
    ///   - helpTitle: Tooltip/accessibility label for the button.
    ///   - options: The ordered rows to show in the popover. Callers build this
    ///     list (omitting rows whose link is unavailable) so the package view
    ///     stays free of URL/policy decisions.
    public init(helpTitle: String, options: [Option]) {
        self.helpTitle = helpTitle
        self.options = options
    }

    public var body: some View {
        SidebarFooterIconButton(
            systemImage: "questionmark.circle",
            iconSize: iconSize,
            buttonSize: buttonSize
        ) {
            isPopoverPresented.toggle()
        }
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            helpPopover
        })
        .accessibilityElement(children: .ignore)
        .safeHelp(helpTitle)
        .accessibilityLabel(helpTitle)
        .accessibilityIdentifier("SidebarHelpMenuButton")
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options) { option in
                SidebarHelpMenuOptionRow(
                    title: option.title,
                    isExternalLink: option.isExternalLink,
                    shortcutHint: option.shortcutHint,
                    trailingSystemImage: option.trailingSystemImage,
                    accessibilityIdentifier: option.id
                ) {
                    isPopoverPresented = false
                    option.action()
                }
            }
        }
        .padding(8)
        .frame(minWidth: 200)
    }
}
