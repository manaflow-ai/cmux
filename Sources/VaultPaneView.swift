import CmuxFoundation
import SwiftUI

/// Hosts the Vault mode's content behind a Sessions/History tab bar. Both
/// the right-sidebar mount and the pop-out pane mount render this view so
/// the two entrypoints share one implementation.
struct VaultPaneView: View {
    @ObservedObject var store: SessionIndexStore
    let onResume: ((SessionEntry) -> Void)?
    let onOpen: ((SessionEntry) -> Void)?
    let activeSessionKeys: Set<String>
    let onFocus: ((SessionEntry) -> Void)?
    let historyLog: VaultHistoryEventLog
    @AppStorage("vaultPane.tab") private var selectedTabRawValue = VaultPaneTab.sessions.rawValue

    private var selectedTab: VaultPaneTab {
        VaultPaneTab(rawValue: selectedTabRawValue) ?? .sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            switch selectedTab {
            case .sessions:
                SessionIndexView(
                    store: store,
                    onResume: onResume,
                    onOpen: onOpen,
                    activeSessionKeys: activeSessionKeys,
                    onFocus: onFocus
                )
            case .history:
                VaultHistoryView(sessionStore: store, log: historyLog)
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
