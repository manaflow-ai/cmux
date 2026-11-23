import Foundation

/// Localized strings for the browser module. Keys live in
/// Resources/Localizable.xcstrings (en, ja).
nonisolated enum Strings {
    // Toolbar
    static var back: String { String(localized: "browser.toolbar.back", defaultValue: "Back", bundle: .localizedModule) }
    static var forward: String { String(localized: "browser.toolbar.forward", defaultValue: "Forward", bundle: .localizedModule) }
    // retry-prompt-ok: the toolbar's Reload command, not a retry prompt
    static var reload: String { String(localized: "browser.toolbar.reload", defaultValue: "Reload This Page", bundle: .localizedModule) }
    /// The Reload button's right-click menu (cx-2lm4).
    static var menuReload: String { String(localized: "browser.toolbar.menu.reload", defaultValue: "Reload Page", bundle: .localizedModule) }
    static var menuHardReload: String { String(localized: "browser.toolbar.menu.hardReload", defaultValue: "Hard Reload Page", bundle: .localizedModule) }
    static var stop: String { String(localized: "browser.toolbar.stop", defaultValue: "Stop Loading", bundle: .localizedModule) }
    static var bookmarkAdd: String { String(localized: "browser.bookmark.add", defaultValue: "Bookmark This Page", bundle: .localizedModule) }
    static var bookmarkEdit: String { String(localized: "browser.bookmark.edit", defaultValue: "Edit Bookmark", bundle: .localizedModule) }
    static var extensions: String { String(localized: "browser.toolbar.extensions", defaultValue: "Extensions", bundle: .localizedModule) }
    static var extensionMoreFormat: String { String(localized: "browser.extensions.moreFormat", defaultValue: "More Actions for %@", bundle: .localizedModule) }
    static var builtInAdBlocker: String { String(localized: "browser.extensions.builtInAdBlocker", defaultValue: "uBlock Origin (full) is built in", bundle: .localizedModule) }
    static var noExtensions: String { String(localized: "browser.extensions.none", defaultValue: "No extensions installed", bundle: .localizedModule) }

    static func extensionMenuTitle(_ operation: ExtensionMenuOperation) -> String {
        switch operation {
        case .run: String(localized: "browser.extensions.run", defaultValue: "Run", bundle: .localizedModule)
        case .pin: String(localized: "browser.extensions.pin", defaultValue: "Pin to Toolbar", bundle: .localizedModule)
        case .unpin: String(localized: "browser.extensions.unpin", defaultValue: "Unpin from Toolbar", bundle: .localizedModule)
        case .options: String(localized: "browser.extensions.options", defaultValue: "Options", bundle: .localizedModule)
        case .enable: String(localized: "browser.extensions.enable", defaultValue: "Enable", bundle: .localizedModule)
        case .disable: String(localized: "browser.extensions.disable", defaultValue: "Disable", bundle: .localizedModule)
        // retry-prompt-ok: the extensions menu's Reload command (an unpacked extension), not a retry prompt
        case .reload: String(localized: "browser.extensions.reload", defaultValue: "Reload", bundle: .localizedModule)
        case .remove: String(localized: "browser.extensions.remove", defaultValue: "Remove…", bundle: .localizedModule)
        case .siteAccess: String(localized: "browser.extensions.siteAccess", defaultValue: "Site Access and More…", bundle: .localizedModule)
        case .loadUnpacked: String(localized: "browser.extensions.loadUnpacked", defaultValue: "Load Unpacked…", bundle: .localizedModule)
        case .webStore: String(localized: "browser.extensions.webStore", defaultValue: "Chrome Web Store", bundle: .localizedModule)
        case .manage: String(localized: "browser.extensions.manage", defaultValue: "Manage Extensions", bundle: .localizedModule)
        case .homePage: String(localized: "browser.extensions.context.homePage", defaultValue: "Home Page", bundle: .localizedModule)
        case .manageExtension: extensionContextManageExtension
        case .webPermissions: extensionContextViewWebPermissions
        }
    }

    // Extensions bubble and context menu: Chrome's Mac text (generated_resources.grd, use_titlecase).
    static var extensionMenuClose: String { String(localized: "browser.extensions.menu.close", defaultValue: "Close", bundle: .localizedModule) }
    static var extensionMenuPinTooltip: String { String(localized: "browser.extensions.menu.pinTooltip", defaultValue: "Pin", bundle: .localizedModule) }
    static var extensionMenuUnpinTooltip: String { String(localized: "browser.extensions.menu.unpinTooltip", defaultValue: "Unpin", bundle: .localizedModule) }
    static var extensionMenuPinAccessible: String { String(localized: "browser.extensions.menu.pinAccessible", defaultValue: "Pin %@", bundle: .localizedModule) }
    static var extensionMenuUnpinAccessible: String { String(localized: "browser.extensions.menu.unpinAccessible", defaultValue: "Unpin %@", bundle: .localizedModule) }
    static var extensionMenuPinnedAnnouncement: String { String(localized: "browser.extensions.menu.pinnedAnnouncement", defaultValue: "Extension pinned", bundle: .localizedModule) }
    static var extensionMenuUnpinnedAnnouncement: String { String(localized: "browser.extensions.menu.unpinnedAnnouncement", defaultValue: "Extension unpinned", bundle: .localizedModule) }
    static var extensionContextSiteData: String { String(localized: "browser.extensions.context.siteData", defaultValue: "This Can Read and Change Site Data", bundle: .localizedModule) }
    static var extensionContextRemove: String { String(localized: "browser.extensions.context.remove", defaultValue: "Remove from cmux", bundle: .localizedModule) }
    static var extensionContextInstalledByAdmin: String { String(localized: "browser.extensions.context.installedByAdmin", defaultValue: "Installed by Your Administrator", bundle: .localizedModule) }
    static var extensionContextManageExtension: String { String(localized: "browser.extensions.context.manageExtension", defaultValue: "Manage Extension", bundle: .localizedModule) }
    static var extensionContextViewWebPermissions: String { String(localized: "browser.extensions.context.viewWebPermissions", defaultValue: "View Web Permissions", bundle: .localizedModule) }
    static var extensionMenuMoreTooltip: String { String(localized: "browser.extensions.menu.moreTooltip", defaultValue: "More options", bundle: .localizedModule) }
    static var extensionMenuSidePanelTooltip: String { String(localized: "browser.extensions.menu.sidePanelTooltip", defaultValue: "Open side panel", bundle: .localizedModule) }
    static var extensionMenuSidePanelAccessible: String { String(localized: "browser.extensions.menu.sidePanelAccessible", defaultValue: "Open side panel of %@", bundle: .localizedModule) }
    static var extensionMenuGetExtensions: String { String(localized: "browser.extensions.menu.getExtensions", defaultValue: "Get Extensions", bundle: .localizedModule) }
    static var extensionMenuEmptyDetail: String { String(localized: "browser.extensions.menu.emptyDetail", defaultValue: "Add extensions from the Chrome Web Store.", bundle: .localizedModule) }

    /// The title of a section of the Extensions bubble (Chrome's site-access sections).
    static func extensionSection(_ group: ExtensionSiteAccess.Group) -> String {
        switch group {
        case .canSeeAndChange: String(localized: "browser.extensions.menu.section.canSeeAndChange", defaultValue: "Can see and change this site", bundle: .localizedModule)
        case .whenClicked: String(localized: "browser.extensions.menu.section.whenClicked", defaultValue: "Allowed only when clicked", bundle: .localizedModule)
        case .noAccess: String(localized: "browser.extensions.menu.section.noAccess", defaultValue: "No access needed", bundle: .localizedModule)
        }
    }

    /// The line under an extension's name: what it can see and change (Edge's wording); empty
    /// when its manifest was not read.
    static func extensionAccess(_ access: ExtensionSiteAccess) -> String {
        switch access {
        case .allSites: String(localized: "browser.extensions.menu.access.allSites", defaultValue: "Allowed on all sites", bundle: .localizedModule)
        case .thisSite: String(localized: "browser.extensions.menu.access.thisSite", defaultValue: "Allowed on this site", bundle: .localizedModule)
        case .whenClicked: String(localized: "browser.extensions.menu.access.whenClicked", defaultValue: "Allowed when clicked", bundle: .localizedModule)
        case .none: String(localized: "browser.extensions.menu.access.none", defaultValue: "No site access", bundle: .localizedModule)
        case .unknown: ""
        }
    }

    // Address bar
    static func searchWith(engine: String) -> String {
        String(localized: "browser.suggestion.searchWith", defaultValue: "\(engine) Search", bundle: .localizedModule)
    }
    /// Chromium's `IDS_OMNIBOX_TAB_SUGGEST_HINT`: the detail of an open-tab row.
    static var switchToTab: String {
        String(localized: "browser.suggestion.switchToTab", defaultValue: "Switch to Tab", bundle: .localizedModule)
    }
    /// The detail of a calculator row.
    static var calculatorCopyHint: String {
        String(localized: "browser.suggestion.calculatorCopyHint", defaultValue: "Return Copies", bundle: .localizedModule)
    }
    /// Chromium's `IDS_OMNIBOX_KEYWORD_TEXT`: the chip of a search engine keyword session.
    static func searchKeyword(engine: String) -> String {
        String(localized: "browser.omnibar.searchKeyword", defaultValue: "Search \(engine)", bundle: .localizedModule)
    }
    /// Chromium's `IDS_OMNIBOX_EMPTY_HINT`.
    static var omnibarPlaceholder: String {
        String(localized: "browser.omnibar.placeholder", defaultValue: "Search or enter address", bundle: .localizedModule)
    }
    /// Chromium `IDS_CONTEXT_MENU_SHOW_FULL_URLS`.
    static var alwaysShowFullURLs: String {
        String(localized: "browser.omnibar.alwaysShowFullURLs", defaultValue: "Always Show Full URLs", bundle: .localizedModule)
    }
    /// Chromium `IDS_MANAGE_SEARCH_ENGINES_AND_SITE_SEARCH`: opens Settings at the search engine.
    static var manageSearchEngines: String {
        String(localized: "browser.omnibar.manageSearchEngines", defaultValue: "Manage Search Engines…", bundle: .localizedModule)
    }
    static var pasteAndGo: String { String(localized: "browser.omnibar.pasteAndGo", defaultValue: "Paste and Go", bundle: .localizedModule) }
    static var pasteAndSearch: String { String(localized: "browser.omnibar.pasteAndSearch", defaultValue: "Paste and Search", bundle: .localizedModule) }
    static var newTab: String { String(localized: "browser.tab.new", defaultValue: "New Tab", bundle: .localizedModule) }
    static var notSecure: String { String(localized: "browser.address.notSecure", defaultValue: "Not Secure", bundle: .localizedModule) }
    /// Accessibility label of a popup window's read-only address field.

    // Find
    static var findPlaceholder: String { String(localized: "browser.find.placeholder", defaultValue: "Find in page", bundle: .localizedModule) }
    static var findPrevious: String { String(localized: "browser.find.previous", defaultValue: "Previous Match", bundle: .localizedModule) }
    static var findNext: String { String(localized: "browser.find.next", defaultValue: "Next Match", bundle: .localizedModule) }
    static var findDone: String { String(localized: "browser.find.done", defaultValue: "Done", bundle: .localizedModule) }
    static var findMatchCase: String { String(localized: "browser.find.matchCase", defaultValue: "Match Case", bundle: .localizedModule) }
    static var findNoMatches: String { String(localized: "browser.find.noMatches", defaultValue: "No matches", bundle: .localizedModule) }
    static func findPosition(_ index: Int, of count: Int) -> String {
        String(localized: "browser.find.position", defaultValue: "\(index) of \(count)", bundle: .localizedModule)
    }
    static func findCount(_ count: Int) -> String {
        String(localized: "browser.find.count", defaultValue: "\(count) matches", bundle: .localizedModule)
    }

    // Prompts
    static func permissionCamera(_ origin: String) -> String {
        String(localized: "browser.permission.camera", defaultValue: "\(origin) wants to use your camera.", bundle: .localizedModule)
    }
    static func permissionMicrophone(_ origin: String) -> String {
        String(localized: "browser.permission.microphone", defaultValue: "\(origin) wants to use your microphone.", bundle: .localizedModule)
    }
    static func permissionCameraAndMicrophone(_ origin: String) -> String {
        String(localized: "browser.permission.cameraAndMicrophone", defaultValue: "\(origin) wants to use your camera and microphone.", bundle: .localizedModule)
    }
    static func permissionScreenShare(_ origin: String) -> String {
        String(localized: "browser.permission.screenShare", defaultValue: "\(origin) wants to share your screen.", bundle: .localizedModule)
    }
    static var screenShareAllow: String {
        String(localized: "browser.permission.screenShare.allow", defaultValue: "Share Screen", bundle: .localizedModule)
    }
    static var screenShareDontAllow: String {
        String(localized: "browser.permission.screenShare.dontAllow", defaultValue: "Don't Allow", bundle: .localizedModule)
    }
    static func permissionLocation(_ origin: String) -> String {
        String(localized: "browser.permission.location", defaultValue: "\(origin) wants to know your location.", bundle: .localizedModule)
    }
    static func permissionNotifications(_ origin: String) -> String {
        String(localized: "browser.permission.notifications", defaultValue: "\(origin) wants to show notifications.", bundle: .localizedModule)
    }
    /// The automatic-downloads question; `origin` is empty for a page
    /// without one (data:, about:blank).
    static func permissionAutomaticDownloads(_ origin: String) -> String {
        guard !origin.isEmpty else {
            return String(localized: "browser.permission.automaticDownloads.thisPage", defaultValue: "This page wants to download multiple files.", bundle: .localizedModule)
        }
        return String(localized: "browser.permission.automaticDownloads", defaultValue: "\(origin) wants to download multiple files.", bundle: .localizedModule)
    }
    /// Why a download was listed blocked: no one could be asked whether the
    /// site may download multiple files.
    static var downloadBlockedUnanswered: String {
        String(localized: "browser.download.blockedUnanswered", defaultValue: "Blocked: cmux could not ask whether this site may download multiple files.", bundle: .localizedModule)
    }
    /// Why a download was listed blocked: the site's remembered setting.
    static var downloadBlockedBySite: String {
        String(localized: "browser.download.blockedBySite", defaultValue: "Blocked: this site may not download multiple files. Change it in Site settings.", bundle: .localizedModule)
    }
    /// Why a download was listed blocked: the person answered Block.
    static var downloadBlockedDeclined: String {
        String(localized: "browser.download.blockedDeclined", defaultValue: "Blocked: you chose to block multiple downloads from this site.", bundle: .localizedModule)
    }
    static func dialogFrom(_ origin: String) -> String {
        String(localized: "browser.dialog.from", defaultValue: "\(origin) says", bundle: .localizedModule)
    }
    static var allow: String { String(localized: "browser.prompt.allow", defaultValue: "Allow", bundle: .localizedModule) }
    static var ok: String { String(localized: "browser.prompt.ok", defaultValue: "OK", bundle: .localizedModule) }
    static var cancel: String { String(localized: "browser.prompt.cancel", defaultValue: "Cancel", bundle: .localizedModule) }
    // beforeunload (Chrome's wording)
    static var beforeUnloadLeaveTitle: String { String(localized: "browser.beforeUnload.leaveTitle", defaultValue: "Leave site?", bundle: .localizedModule) }
    // retry-prompt-ok: the page's beforeunload question: reloading drops its unsaved changes
    static var beforeUnloadReloadTitle: String { String(localized: "browser.beforeUnload.reloadTitle", defaultValue: "Reload site?", bundle: .localizedModule) }
    static var beforeUnloadMessage: String {
        String(localized: "browser.beforeUnload.message", defaultValue: "Changes that you made may not be saved.", bundle: .localizedModule)
    }
    static var beforeUnloadLeave: String { String(localized: "browser.beforeUnload.leave", defaultValue: "Leave", bundle: .localizedModule) }
    // retry-prompt-ok: the page's beforeunload answer: reloading drops its unsaved changes
    static var beforeUnloadReload: String { String(localized: "browser.beforeUnload.reload", defaultValue: "Reload", bundle: .localizedModule) }

    // Context menu
    static var openImageInNewTab: String { String(localized: "browser.menu.openImageInNewTab", defaultValue: "Open Image in New Tab", bundle: .localizedModule) }
    static var openVideoInNewTab: String { String(localized: "browser.menu.openVideoInNewTab", defaultValue: "Open Video in New Tab", bundle: .localizedModule) }

    // Errors and engines
    static var cefUnavailable: String {
        String(localized: "browser.engine.cefUnavailable", defaultValue: "The Chromium engine is not available in this build.", bundle: .localizedModule)
    }
    static var loadFailedTitle: String {
        String(localized: "browser.error.loadFailed", defaultValue: "Can’t open this page", bundle: .localizedModule)
    }
    // retry-prompt-ok: shown only when loading again would send a form (BrowserLoadError.sentForm, BR-R1)
    static var tryAgain: String { String(localized: "browser.error.tryAgain", defaultValue: "Try Again", bundle: .localizedModule) }
}

extension Strings {
    static var devToolsDockBottom: String {
        String(localized: "browser.devtools.dockBottom", defaultValue: "Dock to Bottom", bundle: .localizedModule)
    }
    static var devToolsDockLeft: String {
        String(localized: "browser.devtools.dockLeft", defaultValue: "Dock to Left", bundle: .localizedModule)
    }
    static var devToolsDockRight: String {
        String(localized: "browser.devtools.dockRight", defaultValue: "Dock to Right", bundle: .localizedModule)
    }
    static var devToolsUndock: String {
        String(localized: "browser.devtools.undock", defaultValue: "Undock into Separate Window", bundle: .localizedModule)
    }
    static var devToolsClose: String {
        String(localized: "browser.devtools.close", defaultValue: "Close Developer Tools", bundle: .localizedModule)
    }
}
