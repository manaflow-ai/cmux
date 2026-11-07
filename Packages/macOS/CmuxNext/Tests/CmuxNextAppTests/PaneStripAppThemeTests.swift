import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import Testing

/// User 2026-11-03: "we need to make sure every single theme, all the UI elements are colored
/// properly". With a light App Theme over a dark terminal theme (GitHub Light over Rose Pine), every
/// pane's tab strip drew the terminal theme's ink on the App Theme's titlebar: the selected tab's
/// title was Rose Pine's #e0def4 on white (1.3:1), the other titles its lavender. The strip's own
/// scope was a terminal-level scope, and a terminal keeps the terminal theme under an App Theme
/// (``AppThemeTerminalScopeTests``); the strip is chrome and takes the App Theme like the sidebar.
@MainActor @Suite struct PaneStripAppThemeTests {
    private let darkTerminal = ThemeInput(background: ThemeRGB(hex: 0x191724), foreground: ThemeRGB(hex: 0xE0DEF4))
    private let lightApp = ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1F2328))

    @Test func aPaneStripDrawsTheAppThemeNotTheTerminalTheme() {
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        store.apply(darkTerminal)
        store.setAppTheme(from: lightApp)
        let workspace = ThemeScope(level: .workspace, parent: ThemeScope(level: .room, parent: app))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        workspace.root(host)
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]),
                                   reveal: LaunchReveal(deadline: .zero))
        host.addSubview(pane)

        let chrome = ThemeTokens.derive(from: lightApp)
        #expect(pane.themeScope.tokens == chrome)
        #expect(pane.stripView.themeScope.tokens == chrome, "the strip draws the terminal theme on the App Theme's titlebar")
        let title = pane.stripView.themeScope.tokens.textPrimary
        #expect(title.contrast(with: chrome.windowBackground.withAlpha(1)) >= ThemeTokens.minimumTextContrast)

        // Match Terminal Theme: the strip follows the terminal theme again with the rest of the chrome.
        store.setAppTheme(from: nil)
        #expect(pane.stripView.themeScope.tokens == ThemeTokens.derive(from: darkTerminal))
    }
}
