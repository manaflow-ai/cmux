import AppKit

/// Gives a chrome the per-tab hooks and presentation of the tab it binds (`BrowserChromeTabState`): every one,
/// nil included, so nothing of the tab shown before stays.
@MainActor
struct BrowserChromeTabHooks {
    let chrome: BrowserChromeView
    let state: BrowserChromeTabState

    func apply() {
        chrome.loadOverride = state.loadOverride
        chrome.onOpenURL = state.onOpenURL
        chrome.onTypedCommit = state.onTypedCommit
        chrome.onReturnFocusToPage = state.onReturnFocusToPage
        chrome.onContentFullscreenChange = state.onContentFullscreenChange
        chrome.machineBadge = state.machineBadge
        chrome.certificateWarningRouter = state.certificateWarningRouter
        chrome.pageInfoCommandRouter = state.pageInfoCommandRouter
        chrome.extensionMenuHandler = state.extensionMenuHandler
        chrome.onFocusModeBadgePress = state.onFocusModeBadgePress
        let bar = chrome.addressBar
        if let engine = state.suggestionEngine, engine !== bar.suggestionEngine { bar.suggestionEngine = engine }
        bar.tabKey = state.tabKey
        if bar.shownProfileBadge != state.profileBadge { bar.setProfileBadge(state.profileBadge) }
        bar.profileBadgeMenu = state.profileBadgeMenu
        bar.machineBadgeMenu = state.machineBadgeMenu
        bar.onBookmarkStar = state.onBookmarkStar
        bar.onPageURLChange = state.onPageURLChange
        bar.rowFavicon = state.rowFavicon
        bar.setBookmarkStar(state.bookmarkStar)
        let buttons = chrome.toolbarButtons
        if buttons.profileName != state.profileName { buttons.profileName = state.profileName }
        buttons.onPress = state.onToolbarPress
        // The tab's toolbar sources, once per tab the toolbar has not been configured for (each source re-arms
        // the toolbar's observation): a switch between tabs already configured sets nothing.
        if buttons.configuredFor !== state {
            buttons.configuredFor = state
            buttons.batchSources { state.configureToolbar?(buttons) }
        }
        chrome.showsFocusModeIndicator = state.showsFocusModeIndicator
        chrome.focusModeExitArmed = state.focusModeExitArmed
        if chrome.accessoryView !== state.accessory?.view {
            chrome.setAccessoryView(state.accessory?.view, height: state.accessory?.height ?? 0)
        }
        if let notice = state.pendingNotice {
            state.pendingNotice = nil
            chrome.showNotice(notice.text, action: notice.action)
        }
    }
}
