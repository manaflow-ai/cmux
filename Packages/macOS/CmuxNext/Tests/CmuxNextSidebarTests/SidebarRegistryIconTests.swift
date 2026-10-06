import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Testing
@testable import CmuxNextSidebar

/// Sidebar items, headers and tab rows draw from the cmux icon registry
/// (one semantic name per meaning) at the size of the text beside them,
/// not stock SF Symbols a size below it.
@MainActor @Suite struct SidebarRegistryIconTests {
    @Test func builtInsNameTheirRegistryIcon() {
        let expected: [SidebarBuiltIn: IconName] = [
            .home: .home, .settings: .settings, .account: .account, .notifications: .notification,
            .history: .history, .bookmarks: .bookmarkManager, .appStore: .store, .newTerminal: .terminalNew,
            .newBrowser: .browserNew, .newAgentChat: .agentChatNew, .customize: .theme,
            .newWorkspace: .workspaceNew, .importSync: .actionDownload,
        ]
        for (builtIn, name) in expected {
            #expect(builtIn.icon == name, "\(builtIn)")
            #expect(builtIn.defaultInfo.icon == name, "\(builtIn)")
        }
    }

    /// First-party apps (Home, App Store) keep their former built-in's icon,
    /// and unresolved references draw the registry icon of their kind.
    @Test func fallbacksNameTheirRegistryIcon() {
        #expect(SidebarBuiltIn.firstParty(appID: "cmux/home") == .home)
        #expect(SidebarBuiltIn.firstParty(appID: "cmux/app-store") == .appStore)
        #expect(SidebarBuiltIn.firstParty(appID: "someone/app") == nil)
        #expect(SidebarItemInfo.fallback(for: .app("cmux/home")).icon == .home)
        #expect(SidebarItemInfo.fallback(for: .app("someone/app")).icon == .appGeneric)
        #expect(SidebarItemInfo.fallback(for: LayoutItemRef(kind: LayoutItemRef.workspaceKind, value: "w")).icon == .workspace)
        #expect(SidebarItemInfo.fallback(for: LayoutItemRef(kind: LayoutItemRef.urlKind, value: "u")).icon == .browser)
        #expect(SidebarItemInfo.fallback(for: LayoutItemRef(kind: "nonsense", value: "x")).icon == .iconMissing)
    }

    /// An item's glyph is a row-size registry icon, like a workspace row's;
    /// on a list well it fills the well short of its edge.
    @Test func anItemDrawsItsIconAtRowSize() throws {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        row.configure(SidebarBuiltIn.home.defaultInfo, style: .list)
        row.layoutSubtreeIfNeeded()
        let well = SidebarStyle.wellGlyphSize
        #expect(well == SidebarStyle.iconBox - Metrics.space2)
        #expect(try #require(row.glyphImage).size == NSSize(width: well, height: well))
        #expect(row.glyphFrame.width == well)
        let side = SidebarStyle.kindGlyphSize
        let plain = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        plain.configure(SidebarBuiltIn.settings.defaultInfo, style: .chip)
        plain.layoutSubtreeIfNeeded()
        #expect(try #require(plain.glyphImage).size == NSSize(width: side, height: side))
    }

    /// An item the App gave only an SF Symbol (a third-party app) still draws it.
    @Test func anItemWithoutARegistryIconDrawsItsSymbol() {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        row.configure(SidebarItemInfo(title: "Logs", symbol: "doc.text"), style: .list)
        row.layoutSubtreeIfNeeded()
        #expect(row.glyphImage != nil)
    }

    @Test func tabKindsNameTheirRegistryIcon() {
        #expect(SidebarTabKind.terminal.icon == .terminal)
        #expect(SidebarTabKind.browser.icon == .browser)
        #expect(SidebarTabKind.remoteTerminal.icon == .network)
        #expect(SidebarTabKind.conversation.icon == .agentChat)
        #expect(SidebarTabKind.agentChat.icon == .agentChat)
        #expect(SidebarTabKind.other("x").icon == .placeholder)
    }

    /// A listed tab's icon matches its caption-size title instead of a 10 pt glyph.
    @Test func aTabRowIconMatchesItsTitle() {
        #expect(SidebarStyle.tabIconSize == .iconRowSize(forLabelPointSize: SidebarStyle.subtitleFont.pointSize))
        #expect(SidebarStyle.tabIconSize >= .iconFloor)
    }

    /// Disclosure chevrons come from the registry at the chevron box size.
    @Test func chevronsComeFromTheRegistry() {
        let collapsed = SidebarStyle.chevron(collapsed: true)
        let expanded = SidebarStyle.chevron(collapsed: false)
        let side = max(CGFloat.iconFloor, Metrics.smallIconSize)
        #expect(collapsed.size == NSSize(width: side, height: side))
        #expect(collapsed.isTemplate && expanded.isTemplate)
        #expect(collapsed !== expanded)
    }
}
