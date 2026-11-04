import Foundation

/// Localized strings for the browser module. Keys live in
/// Resources/Localizable.xcstrings (en, ja).
nonisolated enum Strings {
    // Toolbar
    static var back: String { String(localized: "browser.toolbar.back", defaultValue: "Back", bundle: .module) }
    static var forward: String { String(localized: "browser.toolbar.forward", defaultValue: "Forward", bundle: .module) }
    static var reload: String { String(localized: "browser.toolbar.reload", defaultValue: "Reload This Page", bundle: .module) }
    /// The Reload button's right-click menu (cx-2lm4).
    static var menuReload: String { String(localized: "browser.toolbar.menu.reload", defaultValue: "Reload Page", bundle: .module) }
    static var menuHardReload: String { String(localized: "browser.toolbar.menu.hardReload", defaultValue: "Hard Reload Page", bundle: .module) }
    static var stop: String { String(localized: "browser.toolbar.stop", defaultValue: "Stop Loading", bundle: .module) }
    static var bookmarkAdd: String { String(localized: "browser.bookmark.add", defaultValue: "Bookmark This Page", bundle: .module) }
    static var bookmarkEdit: String { String(localized: "browser.bookmark.edit", defaultValue: "Edit Bookmark", bundle: .module) }
    static var extensions: String { String(localized: "browser.toolbar.extensions", defaultValue: "Extensions", bundle: .module) }
    static var extensionMoreFormat: String { String(localized: "browser.extensions.moreFormat", defaultValue: "More Actions for %@", bundle: .module) }
    static var builtInAdBlocker: String { String(localized: "browser.extensions.builtInAdBlocker", defaultValue: "uBlock Origin (full) is built in", bundle: .module) }
    static var noExtensions: String { String(localized: "browser.extensions.none", defaultValue: "No extensions installed", bundle: .module) }

    static func extensionMenuTitle(_ operation: ExtensionMenuOperation) -> String {
        switch operation {
        case .run: String(localized: "browser.extensions.run", defaultValue: "Run", bundle: .module)
        case .pin: String(localized: "browser.extensions.pin", defaultValue: "Pin to Toolbar", bundle: .module)
        case .unpin: String(localized: "browser.extensions.unpin", defaultValue: "Unpin from Toolbar", bundle: .module)
        case .options: String(localized: "browser.extensions.options", defaultValue: "Options", bundle: .module)
        case .enable: String(localized: "browser.extensions.enable", defaultValue: "Enable", bundle: .module)
        case .disable: String(localized: "browser.extensions.disable", defaultValue: "Disable", bundle: .module)
        case .reload: String(localized: "browser.extensions.reload", defaultValue: "Reload", bundle: .module)
        case .remove: String(localized: "browser.extensions.remove", defaultValue: "Remove…", bundle: .module)
        case .siteAccess: String(localized: "browser.extensions.siteAccess", defaultValue: "Site Access and More…", bundle: .module)
        case .loadUnpacked: String(localized: "browser.extensions.loadUnpacked", defaultValue: "Load Unpacked…", bundle: .module)
        case .webStore: String(localized: "browser.extensions.webStore", defaultValue: "Chrome Web Store", bundle: .module)
        case .manage: String(localized: "browser.extensions.manage", defaultValue: "Manage Extensions", bundle: .module)
        case .homePage: String(localized: "browser.extensions.context.homePage", defaultValue: "Home Page", bundle: .module)
        case .manageExtension: extensionContextManageExtension
        case .webPermissions: extensionContextViewWebPermissions
        }
    }

    // Extensions bubble and context menu: Chrome's Mac text (generated_resources.grd, use_titlecase).
    static var extensionMenuClose: String { String(localized: "browser.extensions.menu.close", defaultValue: "Close", bundle: .module) }
    static var extensionMenuPinTooltip: String { String(localized: "browser.extensions.menu.pinTooltip", defaultValue: "Pin", bundle: .module) }
    static var extensionMenuUnpinTooltip: String { String(localized: "browser.extensions.menu.unpinTooltip", defaultValue: "Unpin", bundle: .module) }
    static var extensionMenuPinAccessible: String { String(localized: "browser.extensions.menu.pinAccessible", defaultValue: "Pin %@", bundle: .module) }
    static var extensionMenuUnpinAccessible: String { String(localized: "browser.extensions.menu.unpinAccessible", defaultValue: "Unpin %@", bundle: .module) }
    static var extensionMenuPinnedAnnouncement: String { String(localized: "browser.extensions.menu.pinnedAnnouncement", defaultValue: "Extension pinned", bundle: .module) }
    static var extensionMenuUnpinnedAnnouncement: String { String(localized: "browser.extensions.menu.unpinnedAnnouncement", defaultValue: "Extension unpinned", bundle: .module) }
    static var extensionContextSiteData: String { String(localized: "browser.extensions.context.siteData", defaultValue: "This Can Read and Change Site Data", bundle: .module) }
    static var extensionContextRemove: String { String(localized: "browser.extensions.context.remove", defaultValue: "Remove from cmux", bundle: .module) }
    static var extensionContextInstalledByAdmin: String { String(localized: "browser.extensions.context.installedByAdmin", defaultValue: "Installed by Your Administrator", bundle: .module) }
    static var extensionContextManageExtension: String { String(localized: "browser.extensions.context.manageExtension", defaultValue: "Manage Extension", bundle: .module) }
    static var extensionContextViewWebPermissions: String { String(localized: "browser.extensions.context.viewWebPermissions", defaultValue: "View Web Permissions", bundle: .module) }
    static var extensionMenuMoreTooltip: String { String(localized: "browser.extensions.menu.moreTooltip", defaultValue: "More options", bundle: .module) }
    static var extensionMenuSidePanelTooltip: String { String(localized: "browser.extensions.menu.sidePanelTooltip", defaultValue: "Open side panel", bundle: .module) }
    static var extensionMenuSidePanelAccessible: String { String(localized: "browser.extensions.menu.sidePanelAccessible", defaultValue: "Open side panel of %@", bundle: .module) }
    static var extensionMenuGetExtensions: String { String(localized: "browser.extensions.menu.getExtensions", defaultValue: "Get Extensions", bundle: .module) }
    static var extensionMenuEmptyDetail: String { String(localized: "browser.extensions.menu.emptyDetail", defaultValue: "Add extensions from the Chrome Web Store.", bundle: .module) }

    /// The title of a section of the Extensions bubble (Chrome's site-access sections).
    static func extensionSection(_ group: ExtensionSiteAccess.Group) -> String {
        switch group {
        case .canSeeAndChange: String(localized: "browser.extensions.menu.section.canSeeAndChange", defaultValue: "Can see and change this site", bundle: .module)
        case .whenClicked: String(localized: "browser.extensions.menu.section.whenClicked", defaultValue: "Allowed only when clicked", bundle: .module)
        case .noAccess: String(localized: "browser.extensions.menu.section.noAccess", defaultValue: "No access needed", bundle: .module)
        }
    }

    /// The line under an extension's name: what it can see and change (Edge's wording); empty
    /// when its manifest was not read.
    static func extensionAccess(_ access: ExtensionSiteAccess) -> String {
        switch access {
        case .allSites: String(localized: "browser.extensions.menu.access.allSites", defaultValue: "Allowed on all sites", bundle: .module)
        case .thisSite: String(localized: "browser.extensions.menu.access.thisSite", defaultValue: "Allowed on this site", bundle: .module)
        case .whenClicked: String(localized: "browser.extensions.menu.access.whenClicked", defaultValue: "Allowed when clicked", bundle: .module)
        case .none: String(localized: "browser.extensions.menu.access.none", defaultValue: "No site access", bundle: .module)
        case .unknown: ""
        }
    }

    // Address bar
    static func searchWith(engine: String) -> String {
        String(localized: "browser.suggestion.searchWith", defaultValue: "\(engine) Search", bundle: .module)
    }
    /// Chromium's `IDS_OMNIBOX_TAB_SUGGEST_HINT`: the detail of an open-tab row.
    static var switchToTab: String {
        String(localized: "browser.suggestion.switchToTab", defaultValue: "Switch to Tab", bundle: .module)
    }
    /// The detail of a calculator row.
    static var calculatorCopyHint: String {
        String(localized: "browser.suggestion.calculatorCopyHint", defaultValue: "Return Copies", bundle: .module)
    }
    /// Chromium's `IDS_OMNIBOX_KEYWORD_TEXT`: the chip of a search engine keyword session.
    static func searchKeyword(engine: String) -> String {
        String(localized: "browser.omnibar.searchKeyword", defaultValue: "Search \(engine)", bundle: .module)
    }
    /// Chromium's `IDS_OMNIBOX_EMPTY_HINT`.
    static var omnibarPlaceholder: String {
        String(localized: "browser.omnibar.placeholder", defaultValue: "Search or type URL", bundle: .module)
    }
    /// Chromium `IDS_CONTEXT_MENU_SHOW_FULL_URLS`.
    static var alwaysShowFullURLs: String {
        String(localized: "browser.omnibar.alwaysShowFullURLs", defaultValue: "Always Show Full URLs", bundle: .module)
    }
    /// Chromium `IDS_MANAGE_SEARCH_ENGINES_AND_SITE_SEARCH`: opens Settings at the search engine.
    static var manageSearchEngines: String {
        String(localized: "browser.omnibar.manageSearchEngines", defaultValue: "Manage Search Engines…", bundle: .module)
    }
    static var pasteAndGo: String { String(localized: "browser.omnibar.pasteAndGo", defaultValue: "Paste and Go", bundle: .module) }
    static var pasteAndSearch: String { String(localized: "browser.omnibar.pasteAndSearch", defaultValue: "Paste and Search", bundle: .module) }
    static var newTab: String { String(localized: "browser.tab.new", defaultValue: "New Tab", bundle: .module) }
    static var notSecure: String { String(localized: "browser.address.notSecure", defaultValue: "Not Secure", bundle: .module) }
    /// Accessibility label of a popup window's read-only address field.

    // Find
    static var findPlaceholder: String { String(localized: "browser.find.placeholder", defaultValue: "Find in page", bundle: .module) }
    static var findPrevious: String { String(localized: "browser.find.previous", defaultValue: "Previous Match", bundle: .module) }
    static var findNext: String { String(localized: "browser.find.next", defaultValue: "Next Match", bundle: .module) }
    static var dismissNotice: String { String(localized: "browser.notice.dismiss", defaultValue: "Dismiss", bundle: .module) }
    static var findDone: String { String(localized: "browser.find.done", defaultValue: "Done", bundle: .module) }
    static var findMatchCase: String { String(localized: "browser.find.matchCase", defaultValue: "Match Case", bundle: .module) }
    static var findNoMatches: String { String(localized: "browser.find.noMatches", defaultValue: "No matches", bundle: .module) }
    static func findPosition(_ index: Int, of count: Int) -> String {
        String(localized: "browser.find.position", defaultValue: "\(index) of \(count)", bundle: .module)
    }
    static func findCount(_ count: Int) -> String {
        String(localized: "browser.find.count", defaultValue: "\(count) matches", bundle: .module)
    }

    // Prompts
    static func permissionCamera(_ origin: String) -> String {
        String(localized: "browser.permission.camera", defaultValue: "\(origin) wants to use your camera.", bundle: .module)
    }
    static func permissionMicrophone(_ origin: String) -> String {
        String(localized: "browser.permission.microphone", defaultValue: "\(origin) wants to use your microphone.", bundle: .module)
    }
    static func permissionCameraAndMicrophone(_ origin: String) -> String {
        String(localized: "browser.permission.cameraAndMicrophone", defaultValue: "\(origin) wants to use your camera and microphone.", bundle: .module)
    }
    static func permissionLocation(_ origin: String) -> String {
        String(localized: "browser.permission.location", defaultValue: "\(origin) wants to know your location.", bundle: .module)
    }
    static func permissionNotifications(_ origin: String) -> String {
        String(localized: "browser.permission.notifications", defaultValue: "\(origin) wants to show notifications.", bundle: .module)
    }
    /// The automatic-downloads question; `origin` is empty for a page
    /// without one (data:, about:blank).
    static func permissionAutomaticDownloads(_ origin: String) -> String {
        guard !origin.isEmpty else {
            return String(localized: "browser.permission.automaticDownloads.thisPage", defaultValue: "This page wants to download multiple files.", bundle: .module)
        }
        return String(localized: "browser.permission.automaticDownloads", defaultValue: "\(origin) wants to download multiple files.", bundle: .module)
    }
    /// Why a download was listed blocked: no one could be asked whether the
    /// site may download multiple files.
    static var downloadBlockedUnanswered: String {
        String(localized: "browser.download.blockedUnanswered", defaultValue: "Blocked: cmux could not ask whether this site may download multiple files.", bundle: .module)
    }
    /// Why a download was listed blocked: the site's remembered setting.
    static var downloadBlockedBySite: String {
        String(localized: "browser.download.blockedBySite", defaultValue: "Blocked: this site may not download multiple files. Change it in Site settings.", bundle: .module)
    }
    /// Why a download was listed blocked: the person answered Block.
    static var downloadBlockedDeclined: String {
        String(localized: "browser.download.blockedDeclined", defaultValue: "Blocked: you chose to block multiple downloads from this site.", bundle: .module)
    }
    static func dialogFrom(_ origin: String) -> String {
        String(localized: "browser.dialog.from", defaultValue: "\(origin) says", bundle: .module)
    }
    static var allow: String { String(localized: "browser.prompt.allow", defaultValue: "Allow", bundle: .module) }
    static var ok: String { String(localized: "browser.prompt.ok", defaultValue: "OK", bundle: .module) }
    static var cancel: String { String(localized: "browser.prompt.cancel", defaultValue: "Cancel", bundle: .module) }
    // beforeunload (Chrome's wording)
    static var beforeUnloadLeaveTitle: String { String(localized: "browser.beforeUnload.leaveTitle", defaultValue: "Leave site?", bundle: .module) }
    static var beforeUnloadReloadTitle: String { String(localized: "browser.beforeUnload.reloadTitle", defaultValue: "Reload site?", bundle: .module) }
    static var beforeUnloadMessage: String {
        String(localized: "browser.beforeUnload.message", defaultValue: "Changes that you made may not be saved.", bundle: .module)
    }
    static var beforeUnloadLeave: String { String(localized: "browser.beforeUnload.leave", defaultValue: "Leave", bundle: .module) }
    static var beforeUnloadReload: String { String(localized: "browser.beforeUnload.reload", defaultValue: "Reload", bundle: .module) }

    // Context menu
    static var openImageInNewTab: String { String(localized: "browser.menu.openImageInNewTab", defaultValue: "Open Image in New Tab", bundle: .module) }
    static var openVideoInNewTab: String { String(localized: "browser.menu.openVideoInNewTab", defaultValue: "Open Video in New Tab", bundle: .module) }

    // Errors and engines
    static var cefUnavailable: String {
        String(localized: "browser.engine.cefUnavailable", defaultValue: "The Chromium engine is not available in this build.", bundle: .module)
    }
    /// Chromium was not started: the app's open-file limit is too low (`CEFUnavailableReason.openFileLimit`).
    static func cefOpenFileLimit(_ limit: UInt64) -> String {
        String(format: String(localized: "browser.engine.openFileLimit",
                              defaultValue: "cmux can’t open web pages: its open-file limit is %llu. Start cmux from Finder or the Dock, or raise the limit with ulimit -n before you start it.",
                              bundle: .module), limit)
    }
    static var loadFailedTitle: String {
        String(localized: "browser.error.loadFailed", defaultValue: "Can’t open this page", bundle: .module)
    }
    static var tryAgain: String { String(localized: "browser.error.tryAgain", defaultValue: "Try Again", bundle: .module) }
}

extension Strings {
    static var devToolsDockBottom: String {
        String(localized: "browser.devtools.dockBottom", defaultValue: "Dock to Bottom", bundle: .module)
    }
    static var devToolsDockLeft: String {
        String(localized: "browser.devtools.dockLeft", defaultValue: "Dock to Left", bundle: .module)
    }
    static var devToolsDockRight: String {
        String(localized: "browser.devtools.dockRight", defaultValue: "Dock to Right", bundle: .module)
    }
    static var devToolsUndock: String {
        String(localized: "browser.devtools.undock", defaultValue: "Undock into Separate Window", bundle: .module)
    }
    static var devToolsClose: String {
        String(localized: "browser.devtools.close", defaultValue: "Close Developer Tools", bundle: .module)
    }
}
