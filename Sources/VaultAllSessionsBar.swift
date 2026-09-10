import SwiftUI

/// Chrome row shown for every Vault grouping: session search and view density.
/// Mounted directly by
/// `SessionIndexView` above the table boundary, mirroring the existing control
/// bar (safe to observe the store here — never inside table rows).
struct VaultAllSessionsBar: View {
    @Binding var searchText: String
    /// Shared row-density preference. Default view shows repository/branch
    /// details; compact view hides that second line in every Vault grouping.
    @Binding var isCompactView: Bool
    /// Enter — peek the top search result.
    let onPeekTopResult: () -> Void
    /// Cmd+Enter — resume the top search result.
    let onResumeTopResult: () -> Void

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var globalFontPercent
    @State private var viewMenuPresenter = VaultSessionViewMenuPresenter()

    private var searchFieldHeight: CGFloat {
        _ = globalFontPercent
        return SidebarSearchField.visibleHeight
    }

    var body: some View {
        HStack(spacing: RightSidebarChromeMetrics.headerControlSpacing) {
            searchField
            viewMenuButton
        }
        .frame(height: searchFieldHeight)
        // The grouping row already supplies the gap below Recent. Do not add
        // another top inset or center the editor inside a taller menu button.
        // The outer insets are the mode bar's and the grouping pills', so the
        // field's bezel and the view control sit on the chrome's columns.
        .padding(.leading, SidebarSearchField.leadingPadding)
        .padding(.trailing, RightSidebarChromeMetrics.headerTrailingPadding)
        .padding(.top, SidebarSearchField.topPadding)
        .padding(.bottom, RightSidebarChromeMetrics.barVerticalPadding)
    }

    private var searchField: some View {
        SidebarSearchFieldView(
            text: $searchText,
            placeholder: String(localized: "sessionIndex.allSessions.searchPlaceholder",
                                defaultValue: "Search sessions…"),
            accessibilityIdentifier: "VaultAllSessionsSearchField",
            onSubmit: onPeekTopResult,
            onCommandSubmit: onResumeTopResult
        )
        .frame(height: searchFieldHeight)
        // The field owns the flexible width; the view control keeps its
        // standard 20-point target at the trailing edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .titlebarInteractiveControl()
    }

    /// Same control family as the mode bar's close and open-as-pane buttons:
    /// a 20-point target drawing a 10-point symbol, with the shared hover
    /// treatment. The Default / Compact picker opens as a native menu below it.
    private var viewMenuButton: some View {
        Button {
            viewMenuPresenter.present(isCompactView: isCompactView) { isCompactView = $0 }
        } label: {
            HeaderChromeIconStyle.symbol("ellipsis")
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarVaultViewMenuIcon"))
        .frame(
            width: RightSidebarChromeMetrics.headerControlSize,
            height: RightSidebarChromeMetrics.headerControlSize
        )
        .background(VaultSessionViewMenuAnchor(presenter: viewMenuPresenter))
        .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
            keyPrefix: "rightSidebarVaultViewMenu",
            isVisible: true
        )
        .help(String(localized: "sessionIndex.view.tooltip", defaultValue: "Choose session view"))
        .accessibilityLabel(Text(VaultSessionViewMenuPresenter.title))
        .accessibilityHint(Text(String(localized: "sessionIndex.view.tooltip", defaultValue: "Choose session view")))
        .accessibilityValue(VaultSessionViewOption(isCompact: isCompactView).label)
        .accessibilityIdentifier("VaultSessionOptionsMenu")
        .titlebarInteractiveControl()
    }
}
