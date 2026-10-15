import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// The pinned Chief row at the top of the left sidebar, above the workspace list.
///
/// It is a navigation row, not a workspace: one line, the workspace title
/// typography, and the same selection fill a selected workspace row paints
/// (accent, subtle wash or a configured selection color), so the sidebar keeps
/// exactly one selected row. Like workspace rows it has no hover fill. It sits
/// in the band `SidebarWorkspaceListMetrics` reserves between the titlebar and
/// the first workspace row, for every list implementation.
struct SidebarChiefHomeRow: View {
    let isSelected: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let globalFontMagnificationPercent: Int
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: ChiefPanel.iconSystemName)
                    .font(font(12, weight: .medium))
                    .foregroundColor(isSelected ? primaryColor : Color.secondary)
                    .frame(width: 16 * settings.sidebarFontScale)
                Text(ChiefStrings.chiefName)
                    .font(font(12.5, weight: .semibold))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SidebarChiefHomeUnreadBadge(
                    side: 16 * settings.sidebarFontScale,
                    font: font(9, weight: .semibold),
                    fillColor: badgeFillColor,
                    textColor: isSelected ? primaryColor : .white
                )
            }
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
            .frame(height: SidebarWorkspaceListMetrics.homeRowHeight)
            .contentShape(Rectangle())
            .background(selectionBackground)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .help(String(localized: "sidebar.chiefHome.tooltip", defaultValue: "Talk to Chief"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ChiefStrings.chiefName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("SidebarChiefHomeRow")
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            if usesSubtleSelection {
                SidebarSelectionWindowActivationReader { isEmphasized in
                    backgroundShape(isEmphasized: isEmphasized)
                }
            } else {
                backgroundShape(isEmphasized: true)
            }
        }
    }

    private func backgroundShape(isEmphasized: Bool) -> some View {
        let style = backgroundStyle(isEmphasized: isEmphasized)
        let drawsBorder = settings.activeTabIndicatorStyle.drawsActiveBorder(
            isActive: true,
            increaseContrast: colorSchemeContrast == .increased
        )
        return RoundedRectangle(cornerRadius: 6)
            .fill(style.color.map { Color(nsColor: $0).opacity(style.opacity) } ?? .clear)
            .overlay {
                if drawsBorder, let edge = style.edgeColor ?? style.color {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: edge), lineWidth: 1)
                }
            }
    }

    private func backgroundStyle(isEmphasized: Bool) -> SidebarWorkspaceRowBackgroundStyle {
        sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: true,
            isMultiSelected: false,
            customColorHex: nil,
            colorScheme: colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex,
            subtleSelection: settings.subtleSelection,
            brightenInDarkMode: settings.brightenInDarkMode,
            isEmphasized: isEmphasized,
            increaseContrast: colorSchemeContrast == .increased,
            accent: settings.accentColor
        )
    }

    private var usesSubtleSelection: Bool {
        sidebarUsesSubtleSelection(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            subtleSelection: settings.subtleSelection,
            sidebarSelectionColorHex: settings.selectionColorHex
        )
    }

    private var primaryColor: Color {
        guard isSelected else { return .primary }
        let background = sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex,
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            subtleSelection: settings.subtleSelection,
            accent: settings.accentColor
        )
        return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(on: background, opacity: 1))
    }

    private var badgeFillColor: Color {
        if let hex = settings.notificationBadgeColorHex, let color = NSColor(hex: hex) {
            return Color(nsColor: color)
        }
        return isSelected ? primaryColor.opacity(0.25) : settings.accentColor.color
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

/// Chief's unread count beside the Home row, drawn like a workspace's unread badge.
///
/// A separate view so only it observes `ChiefService.unreadCount`: a new Chief
/// message re-renders the badge, never the sidebar.
private struct SidebarChiefHomeUnreadBadge: View {
    let side: CGFloat
    let font: Font
    let fillColor: Color
    let textColor: Color

    var body: some View {
        let unreadCount = ChiefService.shared.unreadCount
        if unreadCount > 0 {
            SidebarWorkspaceUnreadBadge(
                unreadCount: unreadCount,
                side: side,
                font: font,
                fillColor: fillColor,
                textColor: textColor
            )
            .accessibilityHidden(true)
        }
    }
}
