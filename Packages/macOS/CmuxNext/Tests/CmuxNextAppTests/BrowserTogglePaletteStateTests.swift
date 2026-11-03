import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextFocus
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-11-03 (Cmd-Shift-P): "'toggle' options are very confusing, since we don't know
/// the current state". Each browser page and code editor toggle's palette row reads whether it is
/// on now for the focused page (what a run would flip): Developer Tools, Browser Focus Mode,
/// Browser Design Mode, Omnibar, Word Wrap and Editor Minimap. Toggle React Grab has no such state
/// (it lives in the page's script world) and keeps a plain row.
@MainActor @Suite(.serialized, .closesItsWindows)
struct BrowserTogglePaletteStateTests {
    init() { _ = NSApplication.shared }

    /// What the rows read, set by each test.
    final class Focused {
        var page: BrowserEntry?
        var focus = FocusState()
        var inspected: WebInspectorTarget?
        var editor: JSONValue?
    }

    static let ids: [ActionID] = [
        "toggleBrowserDeveloperTools", "toggleBrowserFocusMode", "toggleBrowserDesignMode",
        "palette.browserToggleOmnibar", "toggleFileEditorWordWrap", "toggleFileEditorMinimap",
    ]

    /// The app's actions, their palette states reading `focused`.
    static func registry(_ focused: Focused) -> (AppServices, ActionRegistry) {
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        BrowserHandlers.bindPaletteStates(into: services.registry, page: { focused.page }, focus: { focused.focus },
                                          inspected: { focused.inspected })
        for toggle in EditorPreferenceToggle.all { toggle.bindPaletteState(into: services.registry) { focused.editor } }
        services.registry.context = [.browserFocused, .codeEditorFocused]
        return (services, services.registry)
    }

    /// Whether `id`'s palette row shows it on, nil when the row has no state.
    static func state(_ id: ActionID, _ registry: ActionRegistry) -> Bool? {
        registry.action(for: id)?.paletteState?()
    }

    private func onScreen(_ key: String, in services: AppServices) -> (BrowserEntry, NSWindow) {
        let entry = services.cache.browser(for: key, url: URL(string: "about:blank"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        entry.chrome.frame = window.contentLayoutRect
        window.contentView = entry.chrome
        return (entry, window)
    }

    @Test func theAppGivesEachToggleARowStateThatIsOffWithNothingFocused() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in Self.ids {
            #expect(Self.state(id, services.registry) == false, "\(id)")
        }
        #expect(Self.state("toggleReactGrab", services.registry) == nil, "React Grab has no readable state")
    }

    @Test func omnibarRowFollowsTheFocusedPage() throws {
        let focused = Focused()
        let (services, registry) = Self.registry(focused)
        let (entry, window) = onScreen("palette-state-omnibar", in: services)
        defer { window.close(); services.cache.release("palette-state-omnibar") }
        #expect(Self.state("palette.browserToggleOmnibar", registry) == false, "no focused page")
        focused.page = entry
        #expect(Self.state("palette.browserToggleOmnibar", registry) == true, "a page shows its address bar")
        entry.chrome.toggleOmnibar()
        #expect(Self.state("palette.browserToggleOmnibar", registry) == false)
        entry.chrome.toggleOmnibar()
        #expect(Self.state("palette.browserToggleOmnibar", registry) == true)
    }

    @Test func designModeRowFollowsTheFocusedPage() {
        let focused = Focused()
        let (services, registry) = Self.registry(focused)
        let (entry, window) = onScreen("palette-state-design", in: services)
        defer { window.close(); services.cache.release("palette-state-design") }
        focused.page = entry
        #expect(Self.state("toggleBrowserDesignMode", registry) == false)
        entry.chrome.toolbarButtons.modes.designMode = true
        #expect(Self.state("toggleBrowserDesignMode", registry) == true)
        entry.chrome.toolbarButtons.modes.designMode = false
        #expect(Self.state("toggleBrowserDesignMode", registry) == false)
    }

    @Test func focusModeRowFollowsTheFocusedPagesTab() {
        let focused = Focused()
        let (services, registry) = Self.registry(focused)
        let (entry, window) = onScreen("palette-state-focus", in: services)
        defer { window.close(); services.cache.release("palette-state-focus") }
        focused.page = entry
        #expect(Self.state("toggleBrowserFocusMode", registry) == false)
        focused.focus.browserFocusMode = ["another-tab"]
        #expect(Self.state("toggleBrowserFocusMode", registry) == false, "another tab's focus mode")
        focused.focus.browserFocusMode = [entry.tab.id.rawValue, "another-tab"]
        #expect(Self.state("toggleBrowserFocusMode", registry) == true)
        focused.page = nil
        #expect(Self.state("toggleBrowserFocusMode", registry) == false, "no focused page")
    }

    @Test func developerToolsRowFollowsTheInspectedWebKitPage() async throws {
        let focused = Focused()
        let (services, registry) = Self.registry(focused)
        let (entry, window) = onScreen("palette-state-devtools", in: services)
        defer { window.close(); services.cache.release("palette-state-devtools") }
        let target = WebInspectorTarget.browser(entry.tab)
        let webView = try #require(target.webKitView, "a test page is a WebKit tab")
        focused.inspected = target
        #expect(Self.state("toggleBrowserDeveloperTools", registry) == false)
        let inspector = WebKitInspector(webView: webView)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        inspector.show()
        defer {
            inspector.close()
            // The inspector's own window, when WebKit shows it detached.
            for other in NSApp.windows where !before.contains(ObjectIdentifier(other)) && other !== window { other.closeAfterTest() }
        }
        try await PinnedPageTests.until({ inspector.isVisible }, within: .seconds(10), report: { "Web Inspector did not show" })
        #expect(Self.state("toggleBrowserDeveloperTools", registry) == true)
        inspector.close()
        try await PinnedPageTests.until({ !inspector.isVisible }, within: .seconds(10), report: { "Web Inspector did not close" })
        #expect(Self.state("toggleBrowserDeveloperTools", registry) == false)
    }

    @Test func wordWrapRowFollowsTheEditorSetting() {
        let focused = Focused()
        let (_, registry) = Self.registry(focused)
        #expect(Self.state("toggleFileEditorWordWrap", registry) == false, "no setting: off")
        focused.editor = .object(["wordWrap": .string("on")])
        #expect(Self.state("toggleFileEditorWordWrap", registry) == true)
        focused.editor = .object(["wordWrap": .string("bounded")])
        #expect(Self.state("toggleFileEditorWordWrap", registry) == true, "any mode but off wraps")
        // What a run writes now turns the row off.
        focused.editor = .object(["wordWrap": EditorPreferenceToggle.wordWrap.next(in: focused.editor)])
        #expect(Self.state("toggleFileEditorWordWrap", registry) == false)
    }

    @Test func minimapRowFollowsTheEditorSetting() {
        let focused = Focused()
        let (_, registry) = Self.registry(focused)
        focused.editor = .object([:])
        #expect(Self.state("toggleFileEditorMinimap", registry) == false, "no setting: off")
        focused.editor = .object(["minimap": EditorPreferenceToggle.minimap.next(in: focused.editor)])
        #expect(Self.state("toggleFileEditorMinimap", registry) == true)
        focused.editor = .object(["minimap": .object(["enabled": .bool(true)])])
        #expect(Self.state("toggleFileEditorMinimap", registry) == true, "Monaco's {enabled} form")
        focused.editor = .object(["minimap": .bool(false)])
        #expect(Self.state("toggleFileEditorMinimap", registry) == false)
    }
}
