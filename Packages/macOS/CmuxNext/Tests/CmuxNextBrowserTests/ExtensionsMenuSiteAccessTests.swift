import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Extensions bubble groups extensions by what their manifests let them do on the current
/// site, says it under each name, and offers a side panel button only where the action opens the
/// panel.
@MainActor @Suite struct ExtensionsMenuSiteAccessTests {
    static let youtube = URL(string: "https://www.youtube.com/watch?v=1")

    static func facts(_ json: String) throws -> ExtensionManifestFacts {
        try #require(ExtensionManifestFacts(json: Data(json.utf8)))
    }

    @Test func aManifestGivesItsSitesClickAccessAndSidePanel() throws {
        let facts = try Self.facts("""
        {
          // Chromium reads manifests with comments and trailing commas.
          "manifest_version": 3,
          "permissions": ["storage", "activeTab", "sidePanel"],
          "host_permissions": ["https://*.youtube.com/*"],
          "content_scripts": [{"matches": ["https://example.com/*", "https://*.youtube.com/*"], "js": ["a.js"]}],
          "side_panel": {"default_path": "panel.html"},
          "action": {"default_title": "Open"},
        }
        """)
        #expect(facts.hostPatterns == ["https://*.youtube.com/*", "https://example.com/*"])
        #expect(facts.activeTab)
        #expect(facts.sidePanel)
        #expect(!facts.actionPopup)
    }

    @Test func anMV2ManifestNamesItsSitesInPermissions() throws {
        let facts = try Self.facts("""
        {"manifest_version": 2, "permissions": ["tabs", "<all_urls>"], "browser_action": {"default_popup": "p.html"}}
        """)
        #expect(facts.hostPatterns == ["<all_urls>"])
        #expect(facts.actionPopup)
        #expect(ExtensionSiteAccess(facts, url: Self.youtube) == .allSites)
    }

    @Test func accessFollowsTheSite() {
        let some = ExtensionManifestFacts(hostPatterns: ["https://*.youtube.com/*"], activeTab: true)
        #expect(ExtensionSiteAccess(some, url: Self.youtube) == .thisSite)
        #expect(ExtensionSiteAccess(some, url: URL(string: "https://youtube.com/")) == .thisSite)
        #expect(ExtensionSiteAccess(some, url: URL(string: "https://notyoutube.com/")) == .whenClicked)
        #expect(ExtensionSiteAccess(some, url: URL(string: "http://www.youtube.com/")) == .whenClicked, "the pattern is https only")
        #expect(ExtensionSiteAccess(ExtensionManifestFacts(hostPatterns: ["*://*/*"]), url: nil) == .allSites)
        #expect(ExtensionSiteAccess(ExtensionManifestFacts(hostPatterns: ["https://example.com:8080/*"]),
                                    url: URL(string: "https://example.com/a")) == .thisSite)
        #expect(ExtensionSiteAccess(ExtensionManifestFacts(), url: Self.youtube) == .none)
        #expect(ExtensionSiteAccess(nil, url: Self.youtube) == .unknown, "an unread manifest claims nothing")
        #expect(ExtensionSiteAccess(some, url: URL(string: "chrome://extensions/")) == .whenClicked)
    }

    @Test func theSidePanelButtonNeedsAPanelAndNoPopup() {
        let info = BrowserExtensionInfo(id: "a", name: "A", hasAction: true)
        #expect(ExtensionsMenuController.opensSidePanel(info, facts: ExtensionManifestFacts(sidePanel: true)))
        #expect(!ExtensionsMenuController.opensSidePanel(info, facts: ExtensionManifestFacts(sidePanel: true, actionPopup: true)))
        #expect(!ExtensionsMenuController.opensSidePanel(info, facts: ExtensionManifestFacts()))
        #expect(!ExtensionsMenuController.opensSidePanel(info, facts: nil))
        var noAction = info
        noAction.hasAction = false
        #expect(!ExtensionsMenuController.opensSidePanel(noAction, facts: ExtensionManifestFacts(sidePanel: true)))
    }

    @Test func theSiteIsTheWebPagesHost() {
        #expect(ExtensionsMenuController.site(of: Self.youtube) == "www.youtube.com")
        #expect(ExtensionsMenuController.site(of: URL(string: "chrome://extensions/")) == nil)
        #expect(ExtensionsMenuController.site(of: nil) == nil)
    }

    @Test func rowsGroupBySectionInChromesOrderAndSayTheirAccess() {
        let view = ExtensionsMenuView()
        func entry(_ id: String, _ access: ExtensionSiteAccess, sidePanel: Bool = false) -> ExtensionsMenuView.Entry {
            ExtensionsMenuView.Entry(info: BrowserExtensionInfo(id: id, name: id, hasAction: true), icon: NSImage(),
                                     access: access, canPin: true, hasSidePanel: sidePanel, tooltip: nil)
        }
        view.update([entry("none", .none), entry("click", .whenClicked), entry("all", .allSites, sidePanel: true),
                     entry("site", .thisSite)], site: "www.youtube.com")
        #expect(view.shownSections.map(\.0) == [.canSeeAndChange, .whenClicked, .noAccess])
        #expect(view.rows.map(\.extensionID) == ["all", "site", "click", "none"])
        #expect(view.row(for: "all")?.primary.detailLabel.stringValue == Strings.extensionAccess(.allSites))
        #expect(view.row(for: "all")?.focusableButtons.count == 4, "primary, side panel, pin, more")
        #expect(view.row(for: "site")?.focusableButtons.count == 3)

        // Another site moves a row between sections and reuses it.
        let row = view.row(for: "site")
        view.update([entry("site", .whenClicked)], site: "example.com")
        #expect(view.row(for: "site") === row)
        #expect(view.shownSections.map(\.0) == [.whenClicked])
        #expect(row?.primary.detailLabel.stringValue == Strings.extensionAccess(.whenClicked))
    }

    @Test func anUnreadManifestGetsNoSectionAndNoLine() {
        let view = ExtensionsMenuView()
        func entry(_ id: String, _ access: ExtensionSiteAccess) -> ExtensionsMenuView.Entry {
            ExtensionsMenuView.Entry(info: BrowserExtensionInfo(id: id, name: id, hasAction: true), icon: NSImage(),
                                     access: access, canPin: true, hasSidePanel: false, tooltip: nil)
        }
        view.update([entry("unread", .unknown), entry("all", .allSites)], site: "example.com")
        #expect(view.shownSections.map(\.0) == [.canSeeAndChange])
        #expect(view.rows.map(\.extensionID) == ["all", "unread"], "after the sections")
        #expect(view.row(for: "unread")?.primary.detailLabel.isHidden == true)

        // Read later: the same row moves into its section and says its access.
        let row = view.row(for: "unread")
        view.update([entry("unread", .whenClicked), entry("all", .allSites)], site: "example.com")
        #expect(view.row(for: "unread") === row)
        #expect(view.shownSections.map(\.0) == [.canSeeAndChange, .whenClicked])
        #expect(row?.primary.detailLabel.isHidden == false)
    }

    @Test func aPinnedPinIsSelected() {
        let info = BrowserExtensionInfo(id: "a", name: "A", hasAction: true, isPinned: true)
        let row = ExtensionsMenuItemView(info: info, icon: nil, access: .none, canPin: true, hasSidePanel: false)
        #expect(row.pinButton.isSelected)
        row.togglePin()
        #expect(!row.pinButton.isSelected)
        #expect(!row.isPinned)
    }

    /// The panel warms at one size, the rows change, then it opens at the content's size: the
    /// content keeps the size it gave itself instead of taking the card's changes on top of it
    /// (it opened 16 points too wide and too tall, its title clipped).
    @Test func theContentKeepsItsSizeWhenTheCardResizes() {
        let content = ExtensionsMenuView()
        let card = ExtensionsMenuCardView(content: content)
        func entry(_ id: String) -> ExtensionsMenuView.Entry {
            ExtensionsMenuView.Entry(info: BrowserExtensionInfo(id: id, name: id, hasAction: true), icon: NSImage(),
                                     access: .allSites, canPin: true, hasSidePanel: false, tooltip: nil)
        }
        content.update([entry("a")], site: "example.com")
        card.setFrameSize(content.frame.size)
        card.layoutSubtreeIfNeeded()
        card.setFrameSize(NSSize(width: content.frame.width - 16, height: content.frame.height - 16))
        card.layoutSubtreeIfNeeded()
        content.update([entry("a"), entry("b")], site: "example.com")
        let size = content.frame.size
        card.setFrameSize(size)
        card.layoutSubtreeIfNeeded()
        #expect(content.frame.size == size)
        #expect(content.frame.origin == .zero)
    }

    @Test func noExtensionsShowsTheEmptyStateAndTheFooter() {
        let view = ExtensionsMenuView()
        view.update([], site: nil)
        #expect(view.rows.isEmpty)
        #expect(view.focusOrder.count == 3, "Manage Extensions, Get Extensions, close")
        #expect(view.frame.height > ExtensionsMenuStyle.standard.emptyHeight)
    }
}
