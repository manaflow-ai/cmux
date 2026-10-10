import CmuxNextIcons
import Foundation

/// Engine rules for the toolbar buttons. Media, zoom, Favorites, Downloads, design mode,
/// profile, theme and More work on WebKit and Chromium tabs. DevTools needs WebKit's inspector
/// or a running Chromium page; a Chromium tab whose engine is not loaded
/// (hibernated, restored before Chromium started, or Chromium unavailable)
/// shows it disabled with the reason.
public nonisolated struct BrowserToolbarPolicy {
    public nonisolated init() {}
    public static func state(_ button: BrowserToolbarButton, _ facts: BrowserToolbarFacts,
                             shortcut: String? = nil) -> BrowserToolbarButtonState {
        func hinted(_ text: String) -> String { shortcut.map { "\(text) (\($0))" } ?? text }
        switch button {
        case .media:
            return BrowserToolbarButtonState(icon: .mediaHub, label: hinted(Strings.toolbarMedia), isActive: facts.media.isPlaying)
        case .zoom:
            return BrowserToolbarButtonState(icon: .search, label: hinted(Strings.toolbarZoom(BrowserZoom.percent(facts.zoom))))
        case .favorites:
            return BrowserToolbarButtonState(icon: .bookmarkManager, label: hinted(Strings.toolbarFavorites))
        case .downloads:
            return BrowserToolbarButtonState(icon: .actionDownload, label: hinted(Strings.toolbarDownloads),
                                             isActive: facts.downloads.inProgress)
        case .designMode:
            return BrowserToolbarButtonState(icon: .theme,
                                             label: hinted(Strings.toolbarDesignMode), isActive: facts.designMode)
        case .profile:
            let label = facts.profileName.map(Strings.toolbarProfile) ?? Strings.toolbarProfileUnknown
            return BrowserToolbarButtonState(icon: .account, label: label)
        case .theme:
            return BrowserToolbarButtonState(icon: facts.colorScheme.icon, label: Strings.toolbarTheme(facts.colorScheme))
        case .devTools:
            guard facts.hostsDevTools else {
                let reason = facts.engine == .cef ? Strings.toolbarDevToolsNeedsChromium : Strings.toolbarDevToolsUnavailable
                return BrowserToolbarButtonState(icon: .tools, label: reason, isEnabled: false)
            }
            return BrowserToolbarButtonState(icon: .tools, label: hinted(Strings.toolbarDevTools),
                                             isActive: facts.devToolsOpen)
        case .overflow:
            return BrowserToolbarButtonState(icon: .actionMore, label: Strings.toolbarMore)
        }
    }
}
