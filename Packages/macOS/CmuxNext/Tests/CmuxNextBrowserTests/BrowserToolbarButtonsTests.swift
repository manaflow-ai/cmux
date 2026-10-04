import AppKit
import Testing
@testable import CmuxNextBrowser

/// The trailing toolbar buttons: order, engine rules, collapse and the
/// per-tab page modes.
@MainActor
@Suite(.serialized) struct BrowserToolbarButtonsTests {
    // MARK: Engine rules

    @Test func everyButtonWorksOnWebKit() {
        let facts = BrowserToolbarFacts(engine: .webkit, hostsDevTools: true, profileName: "Work")
        for button in BrowserToolbarButton.allCases {
            #expect(BrowserToolbarPolicy.state(button, facts).isEnabled, "\(button)")
        }
    }

    @Test func everyButtonWorksOnARunningChromiumTab() {
        let facts = BrowserToolbarFacts(engine: .cef, hostsDevTools: true, devToolsOpen: true)
        for button in BrowserToolbarButton.allCases {
            #expect(BrowserToolbarPolicy.state(button, facts).isEnabled, "\(button)")
        }
        #expect(BrowserToolbarPolicy.state(.devTools, facts).isActive)
    }

    /// A Chromium tab whose engine is not loaded keeps design mode, profile,
    /// theme and More, and shows DevTools disabled with the reason.
    @Test func devToolsNeedsARunningChromiumPage() {
        let facts = BrowserToolbarFacts(engine: .cef, hostsDevTools: false)
        let devTools = BrowserToolbarPolicy.state(.devTools, facts)
        #expect(!devTools.isEnabled)
        #expect(devTools.label == Strings.toolbarDevToolsNeedsChromium)
        for button in BrowserToolbarButton.allCases where button != .devTools {
            #expect(BrowserToolbarPolicy.state(button, facts).isEnabled, "\(button)")
        }
    }

    @Test func devToolsShowsOpenAndClosedOnBothEngines() {
        for engine in [BrowserEngineKind.webkit, .cef] {
            #expect(BrowserToolbarPolicy.state(.devTools, BrowserToolbarFacts(engine: engine, hostsDevTools: true, devToolsOpen: true)).isActive)
            #expect(!BrowserToolbarPolicy.state(.devTools, BrowserToolbarFacts(engine: engine, hostsDevTools: true)).isActive)
        }
    }

    @Test func themeButtonShowsEachMode() {
        let symbols = BrowserColorScheme.allCases.map {
            BrowserToolbarPolicy.state(.theme, BrowserToolbarFacts(engine: .webkit, hostsDevTools: true, colorScheme: $0)).symbol
        }
        #expect(symbols == ["circle.lefthalf.filled", "sun.max", "moon"])
        #expect(BrowserToolbarPolicy.state(.theme, BrowserToolbarFacts(engine: .webkit, hostsDevTools: true, colorScheme: .dark)).label
                    == Strings.toolbarTheme(.dark))
    }

    @Test func designModeShowsItsState() {
        let on = BrowserToolbarPolicy.state(.designMode, BrowserToolbarFacts(engine: .cef, hostsDevTools: true, designMode: true))
        #expect(on.isActive && on.symbol == "paintbrush.pointed.fill")
        let off = BrowserToolbarPolicy.state(.designMode, BrowserToolbarFacts(engine: .cef, hostsDevTools: true), shortcut: "⌃⌥⌘D")
        #expect(!off.isActive && off.symbol == "paintbrush.pointed" && off.label.hasSuffix("(⌃⌥⌘D)"))
    }

    @Test func chromiumColorSchemeIsAMediaEmulation() throws {
        for scheme in BrowserColorScheme.allCases {
            let features = try #require(CEFColorScheme.emulatedMediaParams(scheme)["features"] as? [[String: String]])
            #expect(features == [["name": "prefers-color-scheme", "value": scheme == .system ? "" : scheme.rawValue]])
        }
    }

    // MARK: Chrome

    private func makeChrome(width: CGFloat, tab: MockBrowserTab? = nil) async -> (BrowserChromeView, NSWindow) {
        let tab = tab ?? MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let chrome = BrowserChromeView(tab: tab)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        for _ in 0..<20 { await Task.yield() }
        chrome.layoutSubtreeIfNeeded()
        return (chrome, window)
    }

    /// Design mode, profile, theme, DevTools and More, left to right after
    /// the omnibar, ending at the toolbar's trailing edge.
    @Test func buttonsSitInOrderAtTheTrailingEdge() async throws {
        let (chrome, window) = await makeChrome(width: 1000)
        defer { window.close() }
        let report = chrome.toolbarReport
        let frames = try BrowserToolbarButton.allCases.map { try #require(report.frames["button:\($0.rawValue)"], "\($0)") }
        let omnibar = try #require(report.frames["omnibar"])
        #expect(frames.map(\.minX) == frames.map(\.minX).sorted())
        #expect(frames[0].minX >= omnibar.maxX)
        #expect(abs(report.toolbarBounds.maxX - frames[4].maxX) < 20)
        for button in BrowserToolbarButton.allCases {
            #expect(chrome.toolbarButtons.button(button)?.accessibilityIdentifier() == button.identifier)
        }
    }

    /// As the pane narrows, design mode and DevTools hide first, then
    /// profile and theme; More stays and the pane keeps its width.
    @Test func narrowPanesCollapseIntoMore() async {
        var levels: [Int] = []
        for width in stride(from: CGFloat(1000), through: 200, by: -20) {
            let (chrome, window) = await makeChrome(width: width)
            let buttons = chrome.toolbarButtons
            levels.append(buttons.collapse)
            #expect(window.frame.width == width)
            #expect(buttons.button(.overflow)?.isHidden == false)
            #expect(buttons.collapsedButtons == BrowserToolbarButton.allCases.filter { $0.isCollapsed(at: buttons.collapse) })
            for button in BrowserToolbarButton.allCases {
                #expect(buttons.button(button)?.isHidden == button.isCollapsed(at: buttons.collapse), "\(button) at \(width)")
            }
            window.close()
        }
        #expect(levels.first == 0)
        #expect(levels.last == 2)
        #expect(levels.contains(1))
        #expect(levels == levels.sorted())
    }

    @Test func aPressReportsItsButton() async throws {
        let (chrome, window) = await makeChrome(width: 1000)
        defer { window.close() }
        var pressed: [BrowserToolbarButton] = []
        chrome.toolbarButtons.onPress = { pressed.append($0) }
        for button in BrowserToolbarButton.allCases {
            try #require(chrome.toolbarButtons.button(button) as? NSButton).performClick(nil)
        }
        // A mock page has no DevTools host: that button is disabled.
        #expect(pressed == BrowserToolbarButton.allCases.filter { $0 != .devTools })
        #expect(chrome.toolbarButtons.state(.devTools)?.isEnabled == false)
    }

    /// The chosen color scheme follows the chrome to a new page; design
    /// mode starts off on a new page and when the page navigates.
    @Test func pageModesFollowTheTab() async {
        let first = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let (chrome, window) = await makeChrome(width: 1000, tab: first)
        defer { window.close() }
        let modes = chrome.toolbarButtons.modes
        modes.colorScheme = .dark
        modes.designMode = true
        for _ in 0..<20 { await Task.yield() }
        // On shows as the pressed fill (the app accent is a neutral gray).
        #expect((chrome.toolbarButtons.button(.designMode) as? ChromeIconButton)?.isOn == true)
        #expect((chrome.toolbarButtons.button(.devTools) as? ChromeIconButton)?.isOn == false)
        first.load(URL(string: "https://example.com/next")!)
        for _ in 0..<20 { await Task.yield() }
        #expect(!modes.designMode)
        #expect(chrome.toolbarButtons.state(.theme)?.symbol == "moon")

        modes.designMode = true
        let second = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        chrome.tab = second
        #expect(second.commands.contains(.applyColorScheme(.dark)))
        #expect(!modes.designMode)
    }

    /// WebKit shows and hides an attached Web Inspector by adding and
    /// removing its view beside the page; the container reports both, so
    /// the DevTools button reads the inspector's state again.
    @Test func webKitContainerReportsInspectorViewChanges() {
        let container = WebKitPageContainer(page: NSView())
        var changes = 0
        container.onSubviewsChange = { changes += 1 }
        let inspector = NSView()
        container.addSubview(inspector)
        inspector.removeFromSuperview()
        #expect(changes == 2)
    }
}
