import AppKit
import CmuxFoundation
import SwiftUI

/// A single Home destination, laid out as a row by the workspace list.
struct SidebarChiefHomeRow: View, Equatable {
    let isSelected: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let globalFontMagnificationPercent: Int
    let onSelect: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isSelected == rhs.isSelected
            && lhs.settings == rhs.settings
            && lhs.globalFontMagnificationPercent == rhs.globalFontMagnificationPercent
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "house")
                    .accessibilityHidden(true)
                Text(ChiefStrings.home)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: SidebarWorkspaceListMetrics.homeRowHeight,
                   alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    SidebarSelectionWindowActivationReader { isEmphasized in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isEmphasized
                                ? settings.accentColor.color.opacity(0.18)
                                : Color(nsColor: .labelColor).opacity(0.08))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ChiefStrings.home))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("SidebarChiefHomeRow")
    }

    private var fontSize: CGFloat {
        GlobalFontMagnification.scaledSize(
            12.5 * settings.sidebarFontScale,
            percent: globalFontMagnificationPercent
        )
    }
}
