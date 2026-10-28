import AppKit
import CmuxFoundation
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
/// is not showing. Selected, its trailing button starts a new conversation (the
/// list's compose button). A hairline under it sets the destination apart
/// from the list below. It has no hover fill, like workspace rows, and sits in
/// the band `SidebarWorkspaceListMetrics` reserves below the titlebar.
struct SidebarChiefHomeRow: View {
    let isSelected: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let globalFontMagnificationPercent: Int
    let onSelect: () -> Void
    /// Starts a new conversation; shown as the row's compose button while selected.
    var onNewConversation: (() -> Void)?

    /// The Chief's name from its profile (renamed in Chief Settings).
    @State private var chiefName = ChiefProfile.currentName()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        SidebarChiefHomeAvatar(diameter: (16 * settings.sidebarFontScale).rounded())
                        Text(chiefName)
                            .font(font(12.5, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SidebarChiefHomeStatus(
                            showsUnreadDot: !isSelected,
                            dotColor: dotColor,
                            font: font(10, weight: .regular)
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(chiefName))
                .accessibilityValue(Text(SidebarChiefHomeStatus.accessibilityValue(showsUnread: !isSelected)))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("SidebarChiefHomeRow")
                .help(String(localized: "sidebar.chiefHome.tooltip", defaultValue: "Talk to Chief"))

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

            // The destination's edge: separator color at half strength, centered in the gap.
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 1 / max(1, NSScreen.main?.backingScaleFactor ?? 2))
                .padding(.top, SidebarWorkspaceListMetrics.homeRowBottomGap / 2)
                .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
                    + SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
                .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: ChiefProfile.didChange)) { _ in
            chiefName = ChiefProfile.currentName()
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
/// stays where it is in both modes. The tooltip names the Open Chief
/// shortcut, which toggles Home.
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

    /// The Open Chief shortcut (it toggles Home); nil when unbound.
    private static var shortcutKeys: String? {
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

/// Chief's avatar in the Home row (``ChiefAvatarArtwork``), re-read when the
/// profile changes. Its own view so a profile change re-renders only it.
private struct SidebarChiefHomeAvatar: View {
    let diameter: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    /// Read on appear and on each profile change (not per render).
    @State private var kind: ChiefAvatarArtwork.Kind?

    var body: some View {
        Image(nsImage: ChiefAvatarArtwork.image(kind ?? .chief, diameter: diameter, isDark: colorScheme == .dark))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .accessibilityHidden(true)
            .onAppear { kind = ChiefAvatarArtwork.current() }
            .onReceive(NotificationCenter.default.publisher(for: ChiefProfile.didChange)) { _ in
                kind = ChiefAvatarArtwork.current()
            }
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
