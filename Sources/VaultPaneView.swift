import CmuxFoundation
import SwiftUI

/// Sub-navigation inside the Vault sidebar mode: the existing agent session
/// index ("Sessions") and the unified activity timeline ("History").
enum VaultPaneTab: String, CaseIterable, Identifiable {
    case sessions
    case history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions:
            return String(localized: "vaultPane.tab.sessions", defaultValue: "Sessions")
        case .history:
            return String(localized: "vaultPane.tab.history", defaultValue: "History")
        }
    }

    var symbolName: String {
        switch self {
        case .sessions: return "books.vertical"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// Hosts the Vault mode's content behind a Sessions/History tab bar. Both
/// the right-sidebar mount and the pop-out pane mount render this view so
/// the two entrypoints share one implementation.
struct VaultPaneView: View {
    @ObservedObject var store: SessionIndexStore
    let onResume: ((SessionEntry) -> Void)?
    @AppStorage("vaultPane.tab") private var selectedTabRawValue = VaultPaneTab.sessions.rawValue

    private var selectedTab: VaultPaneTab {
        VaultPaneTab(rawValue: selectedTabRawValue) ?? .sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            switch selectedTab {
            case .sessions:
                SessionIndexView(store: store, onResume: onResume)
            case .history:
                VaultHistoryView(sessionStore: store, log: .shared)
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
