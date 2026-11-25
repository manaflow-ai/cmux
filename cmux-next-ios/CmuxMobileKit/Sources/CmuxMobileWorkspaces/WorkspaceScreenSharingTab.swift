#if os(iOS)
import CmuxTabsKit
import CmuxMobileDesign
import CmuxMobileScreenSharing
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Screen Sharing as a tab of the workspace (the sheet's Open as Tab, user 2026-11-05: "open
/// the Screen Sharing view as a tab, not only a sheet"; the Mac's Mac Screen is a tab). The tab
/// is this phone's own: it lists after the Mac's tabs, asks the Mac for nothing, and Close Tab
/// removes it here only.
extension WorkspaceTabsSource {
    /// The Screen Sharing tab's id: never a Mac tab id (those are the Mac's UUIDs).
    public static let screenSharingTabID = "phone:screen-sharing"
    static let screenSharingTitle = "Screen Sharing"

    /// Open as Tab: the sheet closes and the Screen Sharing tab shows (listed once, however
    /// many times it opens).
    public func openScreenSharingTab() {
        showingScreenSharing = false
        guard offersScreenSharing else { return }
        if !screenSharingTabOpen {
            screenSharingTabOpen = true
            Self.screenSharingTabs.insert(workspaceID)
            refreshTabs()
        }
        activate(Self.screenSharingTabID)
        // The screen leaves the grid for it, as for a tab the Mac just opened.
        openedTab = Self.screenSharingTabID
    }

    /// Close Tab on the Screen Sharing tab: gone from the list; when it showed, the workspace's
    /// opening tab shows instead.
    func closeScreenSharingTab() {
        guard screenSharingTabOpen else { return }
        screenSharingTabOpen = false
        Self.screenSharingTabs.remove(workspaceID)
        refreshTabs()
    }

    /// Whether `id` is listed: one of the Mac's tabs, or the open Screen Sharing tab.
    func isListed(_ id: String?) -> Bool {
        guard let id else { return false }
        if id == Self.screenSharingTabID { return isScreenSharingTabListed }
        return workspaceTab(id) != nil
    }

    /// Open, and Screen Sharing still offered (signed in).
    var isScreenSharingTabListed: Bool { screenSharingTabOpen && offersScreenSharing }

    var screenSharingKitTab: TabsKitTab {
        TabsKitTab(
            id: Self.screenSharingTabID, kind: TabsKitTabKind("screen-sharing"), title: Self.screenSharingTitle,
            subtitle: "Your Macs", systemImage: "rectangle.on.rectangle",
            address: .title(Self.screenSharingTitle, subtitle: "Your Macs"),
            // Back leaves the workspace: the tab has no history of its own.
            navigation: TabsKitNavigationState(canGoBack: true),
            features: [.history, .pageMenu]
        )
    }

    /// The tab's page menu: Close Tab and All Workspaces. The Mac's tab rows (rename, move,
    /// groups, copy) don't apply to a tab the Mac doesn't have.
    var screenSharingPageMenu: [[TabsKitMenuItem]] {
        let close = TabsKitMenuItem(title: "Close Tab", systemImage: "xmark", isDestructive: true) { [weak self] in
            self?.closeScreenSharingTab()
        }
        let leave = TabsKitMenuItem(title: "All Workspaces", systemImage: "square.stack.3d.up") { [weak self] in self?.exit() }
        return [[leave], [close]]
    }
}

/// The Screen Sharing tab's page: the account's Macs and the viewer's choices, as the sheet
/// shows them, under the workspace's chrome.
struct ScreenSharingTabPage: View {
    let source: WorkspaceTabsSource
    let context: TabsKitContentContext

    var body: some View {
        Group {
            if let service = source.screenSharing {
                ScreenSharingPage(service: service)
                    .contentMargins(.top, context.safeAreaInsets.top, for: .scrollContent)
                    .contentMargins(.bottom, context.safeAreaInsets.bottom, for: .scrollContent)
            } else {
                Text("Sign in to cmux to share your Mac's screen.")
                    .font(theme.type.rowSubtitle).foregroundStyle(theme.colors.label2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.colors.bg.color.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screenSharing.tabPage")
    }
}

/// The Screen Sharing tab's card in the grid: its symbol and title (the page's list needs
/// the device hub, which a card never opens).
struct ScreenSharingTabCard: View {
    let insets: EdgeInsets

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(theme.type.heroTitle)
                .foregroundStyle(theme.colors.label2)
            Text(WorkspaceTabsSource.screenSharingTitle)
                .font(theme.type.rowTitle)
                .foregroundStyle(theme.colors.label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, insets.top)
        .background(theme.colors.bg.color)
    }
}
#endif
