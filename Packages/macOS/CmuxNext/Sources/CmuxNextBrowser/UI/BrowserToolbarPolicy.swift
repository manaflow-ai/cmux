import Foundation

/// Engine rules for the toolbar buttons. Design mode, profile, theme and
/// More work on WebKit and Chromium tabs. DevTools needs WebKit's inspector
/// or a running Chromium page; a Chromium tab whose engine is not loaded
/// (hibernated, restored before Chromium started, or Chromium unavailable)
/// shows it disabled with the reason.
public nonisolated enum BrowserToolbarPolicy {
    public static func state(_ button: BrowserToolbarButton, _ facts: BrowserToolbarFacts,
                             shortcut: String? = nil) -> BrowserToolbarButtonState {
        func hinted(_ text: String) -> String { shortcut.map { "\(text) (\($0))" } ?? text }
        switch button {
        case .designMode:
            return BrowserToolbarButtonState(symbol: facts.designMode ? "paintbrush.pointed.fill" : "paintbrush.pointed",
                                             label: hinted(Strings.toolbarDesignMode), isActive: facts.designMode)
        case .profile:
            let label = facts.profileName.map(Strings.toolbarProfile) ?? Strings.toolbarProfileUnknown
            return BrowserToolbarButtonState(symbol: "person.crop.circle", label: label)
        case .theme:
            return BrowserToolbarButtonState(symbol: facts.colorScheme.symbol, label: Strings.toolbarTheme(facts.colorScheme))
        case .devTools:
            guard facts.hostsDevTools else {
                let reason = facts.engine == .cef ? Strings.toolbarDevToolsNeedsChromium : Strings.toolbarDevToolsUnavailable
                return BrowserToolbarButtonState(symbol: "wrench.and.screwdriver", label: reason, isEnabled: false)
            }
            return BrowserToolbarButtonState(symbol: "wrench.and.screwdriver", label: hinted(Strings.toolbarDevTools),
                                             isActive: facts.devToolsOpen)
        case .overflow:
            return BrowserToolbarButtonState(symbol: "ellipsis", label: Strings.toolbarMore)
        }
    }
}
