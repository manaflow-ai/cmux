import CmuxNextIcons
import Foundation

/// Engine rules and icons for the toolbar buttons. Every button Chrome also has draws Chrome's
/// own icon (`browser.toolbar.*`, from Chromium's vector icons): Media, Zoom (plus or minus
/// magnifier by direction), Favorites, Downloads (Chrome's in-progress arrow while one runs),
/// Profile, DevTools and More. Design mode and Theme are cmux's own buttons, so they keep cmux icons.
///
/// Engine rules for the toolbar buttons. Media, zoom, Favorites, Downloads, design mode,
/// profile, theme and More work on WebKit and Chromium tabs. DevTools needs WebKit's inspector
/// or a running Chromium page; a Chromium tab whose engine is not loaded
/// (hibernated, restored before Chromium started, or Chromium unavailable)
/// shows it disabled with the reason.
public nonisolated struct BrowserToolbarPolicy {
    public nonisolated init() {}
    public static func state(_ button: BrowserToolbarButton, _ facts: BrowserToolbarFacts,
                             shortcut: String? = nil) -> BrowserToolbarButtonState {
        var state = labeledState(button, facts, shortcut: shortcut)
        state.showsToolTip = toolTipInforms(button, state, shortcut: shortcut)
        return state
    }

    /// A hover tooltip only where it says more than the icon (Lawrence 2026-10-13: none on
    /// back, forward, refresh "etc"): the zoom level, the profile's name, the current theme, a
    /// disabled button's reason, a shortcut. A bare name (More, Downloads) shows none; the
    /// accessibility label keeps it.
    static func toolTipInforms(_ button: BrowserToolbarButton, _ state: BrowserToolbarButtonState, shortcut: String?) -> Bool {
        guard state.isEnabled else { return true }
        switch button {
        case .zoom, .profile, .theme: return true
        case .overflow: return false
        case .media, .favorites, .downloads, .designMode, .devTools: return shortcut != nil
        }
    }

    private static func labeledState(_ button: BrowserToolbarButton, _ facts: BrowserToolbarFacts,
                                     shortcut: String?) -> BrowserToolbarButtonState {
        func hinted(_ text: String) -> String { shortcut.map { "\(text) (\($0))" } ?? text }
        switch button {
        case .media:
            return BrowserToolbarButtonState(icon: .browserToolbarMedia, label: hinted(Strings.toolbarMedia))
        case .zoom:
            return BrowserToolbarButtonState(icon: BrowserZoom.percent(facts.zoom) < 100 ? .browserToolbarZoomOut : .browserToolbarZoomIn,
                                             label: hinted(Strings.toolbarZoom(BrowserZoom.percent(facts.zoom))))
        case .favorites:
            return BrowserToolbarButtonState(icon: .browserToolbarBookmarks, label: hinted(Strings.toolbarFavorites))
        case .downloads:
            var state = BrowserToolbarButtonState(icon: facts.downloads.inProgress ? .browserToolbarDownloadsActive : .browserToolbarDownloads,
                                                  label: hinted(Strings.toolbarDownloads),
                                                  isActive: facts.downloads.inProgress)
            // Chrome's ring around the Downloads icon while a download runs.
            if facts.downloads.inProgress { state.progress = facts.downloads.progress ?? -1 }
            return state
        case .designMode:
            // chrome-icons: allow Chrome has no Design mode button
            return BrowserToolbarButtonState(icon: .theme,
                                             label: hinted(Strings.toolbarDesignMode),
                                             isEnabled: BrowserPageTunables.uiPointer.value || facts.designMode,
                                             isActive: facts.designMode)
        case .profile:
            let label = facts.profileName.map(Strings.toolbarProfile) ?? Strings.toolbarProfileUnknown
            return BrowserToolbarButtonState(icon: .browserToolbarProfile, label: label)
        case .theme:
            return BrowserToolbarButtonState(icon: facts.colorScheme.icon, label: Strings.toolbarTheme(facts.colorScheme))
        case .devTools:
            guard facts.hostsDevTools else {
                let reason = facts.engine == .cef ? Strings.toolbarDevToolsNeedsChromium : Strings.toolbarDevToolsUnavailable
                return BrowserToolbarButtonState(icon: .browserToolbarDevtools, label: reason, isEnabled: false)
            }
            return BrowserToolbarButtonState(icon: .browserToolbarDevtools, label: hinted(Strings.toolbarDevTools),
                                             isActive: facts.devToolsOpen)
        case .overflow:
            return BrowserToolbarButtonState(icon: .browserToolbarMore, label: Strings.toolbarMore)
        }
    }
}
