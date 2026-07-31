import CmuxFoundation
import SwiftUI

/// Hosts History behind Timeline/By Folder/By Agent views. Both
/// the right-sidebar mount and the pop-out pane mount render this view so
/// the two entrypoints share one implementation.
struct VaultPaneView: View {
    @ObservedObject var store: SessionIndexStore
    @ObservedObject var closedItemStore: ClosedItemHistoryStore
    let onResume: ((SessionEntry) -> Void)?
    let onReopenClosedItem: ((UUID) -> Bool)?
    @AppStorage("vaultPane.tab") private var selectedModeRawValue = VaultHistoryMode.timeline.rawValue

    private var selectedMode: VaultHistoryMode {
        VaultHistoryMode(rawValue: selectedModeRawValue) ?? .timeline
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            VaultHistoryView(
                mode: selectedMode,
                sessionStore: store,
                closedItemStore: closedItemStore,
                log: .shared,
                onResume: onResume,
                onReopenClosedItem: onReopenClosedItem
            )
        }
        .onAppear {
            if VaultHistoryMode(rawValue: selectedModeRawValue) == nil {
                selectedModeRawValue = VaultHistoryMode.timeline.rawValue
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(VaultHistoryMode.allCases) { mode in
                VaultPaneTabButton(mode: mode, isSelected: selectedMode == mode) {
                    selectedModeRawValue = mode.rawValue
                }
            }
            Spacer(minLength: 0)
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
    }
}

private struct VaultPaneTabButton: View {
    let mode: VaultHistoryMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: mode.symbolName)
                    .cmuxFont(
                        size: RightSidebarChromeControlStyle.secondaryIconSize,
                        weight: RightSidebarChromeControlStyle.iconWeight
                    )
                Text(mode.label)
                    .cmuxFont(
                        size: RightSidebarChromeControlStyle.labelSize,
                        weight: RightSidebarChromeControlStyle.labelWeight
                    )
            }
            .rightSidebarChromePill(isSelected: isSelected, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .titlebarInteractiveControl()
        .onHover { isHovered = $0 }
        .help(mode.label)
        .accessibilityIdentifier("VaultPaneTabButton.\(mode.rawValue)")
    }
}
