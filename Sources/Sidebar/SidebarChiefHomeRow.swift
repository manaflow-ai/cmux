import AppKit
import CmuxFoundation
import CmuxHomeCore
import CmuxSettings
import SwiftUI

/// The pinned Chief row at the top of the left sidebar, above the workspace
/// list (or, while Home is selected, above Chief's conversation list).
///
/// A destination, not a workspace, so it never paints the solid workspace
/// selection: selected, it takes a quiet accent tint (18%, neutral in a
/// background window) with primary text, as a macOS source-list destination
/// does and as cmux-next's rail Home item does. It leads with Chief's own
/// avatar at 16 pt (the header's and the list's face), says "Needs you" or
/// "Working…" while a Chief waits or runs, and shows an 8 pt accent dot for unread replies only while Home
/// is not showing. In workspace mode the Open Chief shortcut stays visible beside
/// the quiet status affordance, so the keyboard route is discoverable without a
/// hover and remains present in accessibility captures. Selected, a click returns
/// to the last selected workspace (the row toggles Home, as ⌘⇧C does); it
/// shows no trailing label because the "‹ Workspaces" back row right under it
/// already names the way back. Its compose button still starts a new
/// conversation. A hairline 6 pt under it sets the destination apart from
/// the list below. It has no hover fill, like workspace rows, and sits in
/// the band `SidebarWorkspaceListMetrics` reserves below the titlebar.
struct SidebarChiefHomeRow: View {
    let isSelected: Bool
    let isExpanded: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let globalFontMagnificationPercent: Int
    /// The conversation Home currently shows when this row is dragged into a pane.
    var conversationID: ConversationID?
    let onSelect: () -> Void
    /// Starts a new conversation; shown as the row's compose button while selected.
    var onNewConversation: (() -> Void)?
    /// Expands or collapses the inline Home conversation stack.
    var onToggleExpanded: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button(action: onToggleExpanded) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(font(9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ChiefStrings.conversationsList)
                .accessibilityLabel(Text(ChiefStrings.conversationsList))
                .accessibilityValue(Text(isExpanded ? ChiefStrings.conversationsExpanded : ChiefStrings.conversationsCollapsed))
                .accessibilityIdentifier("SidebarChiefHomeDisclosure")

                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        Image(systemName: "house.fill")
                            .font(font(13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: (16 * settings.sidebarFontScale).rounded())
                            .accessibilityHidden(true)
                        Text(ChiefStrings.home)
                            .font(font(12.5, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Selected: no trailing label; the back row under it names the way back.
                        if !isSelected {
                            SidebarChiefHomeStatus(
                                showsUnreadDot: true,
                                dotColor: dotColor,
                                font: font(10, weight: .regular)
                            )
                            if let keys = SidebarChiefHomeBackRow.shortcutKeys {
                                Text(verbatim: keys)
                                    .font(font(12, weight: .regular))
                                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(ChiefStrings.home))
                .accessibilityValue(Text(verbatim: [
                    SidebarChiefHomeStatus.accessibilityValue(showsUnread: !isSelected),
                    isSelected ? nil : SidebarChiefHomeBackRow.shortcutKeys,
                ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")))
                .accessibilityHint(isSelected ? Text(ChiefStrings.backToWorkspacesTooltip(keys: nil)) : Text(verbatim: ""))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("SidebarChiefHomeRow")
                .help(isSelected
                    ? ChiefStrings.backToWorkspacesTooltip(keys: SidebarChiefHomeBackRow.shortcutKeys)
                    : String(localized: "sidebar.chiefHome.tooltip", defaultValue: "Talk to Chief"))

                if isSelected, let onNewConversation {
                    Button(action: onNewConversation) {
                        Image(systemName: "square.and.pencil")
                            .font(font(12, weight: .regular))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(ChiefStrings.newConversation)
                    .accessibilityLabel(Text(ChiefStrings.newConversation))
                    .accessibilityIdentifier("SidebarChiefHomeNewConversation")
                }
            }
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
            .frame(height: SidebarWorkspaceListMetrics.homeRowHeight)
            .background(selectionBackground)
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)

            // The destination's edge: a separator-color hairline 6 pt under the row.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1 / max(1, NSScreen.main?.backingScaleFactor ?? 2))
                .padding(.top, SidebarWorkspaceListMetrics.homeRowHairlineGap)
                .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
                    + SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
                .accessibilityHidden(true)
        }
        .onDrag {
            guard let registry = AppDelegate.shared?.tabDragTransferRegistry,
                  let provider = ChiefPaneDragPayload(conversationID: conversationID)
                      .provider(with: registry) else {
                return NSItemProvider()
            }
            return provider
        } preview: {
            HStack(spacing: 7) {
                Image(systemName: "house.fill")
                    .font(font(13, weight: .semibold))
                Text(ChiefStrings.home)
                    .font(font(12.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            SidebarSelectionWindowActivationReader { isEmphasized in
                let increaseContrast = colorSchemeContrast == .increased
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEmphasized
                        ? settings.accentColor.color.opacity(increaseContrast ? 0.3 : 0.18)
                        : Color(nsColor: .labelColor).opacity(colorScheme == .dark ? 0.08 : 0.06))
                    .overlay {
                        if increaseContrast {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(settings.accentColor.color.opacity(0.6), lineWidth: 1)
                        }
                    }
            }
        }
    }

    private var dotColor: Color {
        if let hex = settings.notificationBadgeColorHex, let color = NSColor(hex: hex) {
            return Color(nsColor: color)
        }
        return settings.accentColor.color
    }

    private func font(_ baseSize: CGFloat, weight: Font.Weight) -> Font {
        .system(
            size: GlobalFontMagnification.scaledSize(
                baseSize * settings.sidebarFontScale,
                percent: globalFontMagnificationPercent
            ),
            weight: weight
        )
    }
}

/// The way back to the workspace list while Home is selected: "‹ Workspaces"
/// with the workspace count, right under the Home row and above Chief's
/// conversation list. The workspace rows are hidden while Home is selected
/// (one list at a time, as in Messages and cmux-next's rail), so the way back
/// is spelled out instead of relying on clicking the selected Home row again.
/// A back row rather than a Chief | Workspaces segmented control: the
/// sidebar keeps one stack of rows (no new control style), and the Home row
/// stays where it is in both modes. The Open Chief shortcut, which toggles
/// Home, sits at its trailing edge in 12 pt tertiary text (as on the
/// first-run rows) and in its tooltip.
struct SidebarChiefHomeBackRow: View {
    let workspaceCount: Int
    let settings: SidebarTabItemSettingsSnapshot
    let globalFontMagnificationPercent: Int
    let onShowWorkspaces: () -> Void

    var body: some View {
        Button(action: onShowWorkspaces) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(font(10.5, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: (16 * settings.sidebarFontScale).rounded())
                Text(ChiefStrings.backToWorkspaces)
                    .font(font(12.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if workspaceCount > 0 {
                    Text(verbatim: "\(workspaceCount)")
                        .font(font(11, weight: .regular).monospacedDigit())
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .accessibilityHidden(true)
                }
                if let keys = Self.shortcutKeys {
                    // The toggle shortcut, spelled out as on the first-run rows.
                    Text(verbatim: keys)
                        .font(font(12, weight: .regular))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
            .frame(height: SidebarWorkspaceListMetrics.homeBackRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .help(ChiefStrings.backToWorkspacesTooltip(keys: Self.shortcutKeys))
        .accessibilityLabel(Text(ChiefStrings.backToWorkspaces))
        .accessibilityHint(Text(ChiefStrings.backToWorkspacesTooltip(keys: Self.shortcutKeys)))
        .accessibilityIdentifier("SidebarChiefHomeBackToWorkspaces")
    }

    /// The Open Chief shortcut (it toggles Home), as configured now; nil when unbound.
    static var shortcutKeys: String? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .openChief)
        return shortcut.isUnbound ? nil : shortcut.displayString
    }

    private func font(_ baseSize: CGFloat, weight: Font.Weight) -> Font {
        .system(
            size: GlobalFontMagnification.scaledSize(
                baseSize * settings.sidebarFontScale,
                percent: globalFontMagnificationPercent
            ),
            weight: weight
        )
    }
}

/// The Home row's trailing status: "Needs you" (attention color) while a
/// Chief waits on an approval, "Working…" while one runs a turn, else an 8 pt accent dot for unread replies (only while Home is not showing;
/// replies on screen never count, see ``ChiefService/unreadCount``).
///
/// Views of the row, not the sidebar, read ``ChiefService``: a new message or
/// a turn starting re-renders the row, never the sidebar.
private struct SidebarChiefHomeStatus: View {
    let showsUnreadDot: Bool
    let dotColor: Color
    let font: Font

    var body: some View {
        let service = ChiefService.shared
        if Self.needsYou {
            Text(ChiefStrings.homeRowNeedsYou)
                .font(font)
                .foregroundColor(Color(nsColor: .systemOrange))
                .lineLimit(1)
                .accessibilityHidden(true)
        } else if !service.workingConversations.isEmpty {
            Text(ChiefStrings.homeRowWorking)
                .font(font)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
        } else if showsUnreadDot, service.unreadCount > 0 {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }

    /// A running Chief waits on the user's approval.
    @MainActor
    static var needsYou: Bool {
        let service = ChiefService.shared
        return service.workingConversations.contains { service.hasPendingApproval($0) }
    }

    /// The row's spoken status: needs you, working, unread, or nothing.
    @MainActor
    static func accessibilityValue(showsUnread: Bool) -> String {
        let service = ChiefService.shared
        if needsYou { return ChiefStrings.homeRowNeedsYou }
        if !service.workingConversations.isEmpty { return ChiefStrings.homeRowWorking }
        return showsUnread && service.unreadCount > 0 ? ChiefStrings.homeRowUnread : ""
    }
}

/// Hides the workspace rows while Chief Home's conversation list takes the
/// sidebar. Applied to the rows only, so the titlebar drag strip and the
/// minimal-mode titlebar controls stay; the rows stay mounted for an instant return.
struct SidebarWorkspaceRowsChiefHomeCover: ViewModifier {
    let isCovered: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isCovered ? 0 : 1)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
    }
}
