import CmuxFoundation
import SwiftUI

/// Sub-navigation inside History: the unified timeline and agent-session index.
enum VaultPaneTab: String, CaseIterable, Identifiable {
    case sessions
    case history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions:
            return String(localized: "vaultPane.tab.sessions", defaultValue: "Sessions")
        case .history:
            return String(localized: "vaultPane.tab.history", defaultValue: "Timeline")
        }
    }

    var symbolName: String {
        switch self {
        case .sessions: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Hosts History behind Timeline/Sessions tabs. Both
/// the right-sidebar mount and the pop-out pane mount render this view so
/// the two entrypoints share one implementation.
struct VaultPaneView: View {
    @ObservedObject var store: SessionIndexStore
    @ObservedObject var closedItemStore: ClosedItemHistoryStore
    let onResume: ((SessionEntry) -> Void)?
    let onReopenClosedItem: ((UUID) -> Bool)?
    @AppStorage("vaultPane.tab") private var selectedTabRawValue = VaultPaneTab.history.rawValue

    private var selectedTab: VaultPaneTab {
        VaultPaneTab(rawValue: selectedTabRawValue) ?? .history
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            switch selectedTab {
            case .sessions:
                SessionIndexView(store: store, onResume: onResume)
            case .history:
                VaultHistoryView(
                    sessionStore: store,
                    closedItemStore: closedItemStore,
                    log: .shared,
                    onResume: onResume,
                    onReopenClosedItem: onReopenClosedItem
                )
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(VaultPaneTab.allCases) { tab in
                VaultPaneTabButton(tab: tab, isSelected: selectedTab == tab) {
                    selectedTabRawValue = tab.rawValue
                }
            }
            Spacer(minLength: 0)
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
    }
}

private struct VaultPaneTabButton: View {
    let tab: VaultPaneTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: tab.symbolName)
                    .cmuxFont(
                        size: RightSidebarChromeControlStyle.secondaryIconSize,
                        weight: RightSidebarChromeControlStyle.iconWeight
                    )
                Text(tab.label)
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
        .help(tab.label)
        .accessibilityIdentifier("VaultPaneTabButton.\(tab.rawValue)")
    }
}
