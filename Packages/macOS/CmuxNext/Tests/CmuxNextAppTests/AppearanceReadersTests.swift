import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing
import WebKit

/// p06-scheduler-043 with the real readers: the pages and terminals a pane shows follow the app's
/// ``AppearanceSignals`` on their tab's node (`TabContent.followAppearance`), so a Reduce Motion
/// or display-options change with many workspaces open does view work only for the shown tabs,
/// and a page's theme follows Reduce Transparency even when the glass mode stays.
@MainActor @Suite struct AppearanceReadersTests {
    /// The system's display options a test sets.
    @MainActor final class System {
        var options = AppearanceSignals.DisplayOptions()
    }

    /// A page web view, not loaded.
    static func page(_ id: String) -> PageWebView {
        let configuration = WKWebViewConfiguration()
        return PageWebView(descriptor: PageDescriptor(id: id, resource: "appearance", processGroup: .solo, namespaces: []),
                           configuration: configuration, inputReadiness: PageInputReadiness(configuration: configuration),
                           routes: [], route: nil, options: .standard, surface: nil, dynamicResources: nil, pooled: false,
                           load: false, chromium: nil, deadlines: .testing())
    }

    /// The tab nodes of `count` workspaces under one visible window: only the first is shown.
    static func tabs(_ count: Int, under window: VisibilityNode) -> [VisibilityNode] {
        (0..<count).map { VisibilityNode("tab.\($0)", own: $0 == 0 ? .visible : .hidden, parent: window) }
    }

    @Test func aReduceMotionToggleAtSixtyWorkspacesRepaintsOnlyTheShownTerminal() {
        let system = System()
        let design = DesignSettings(display: { system.options })
        let signals = design.signals
        let window = VisibilityNode(root: "window", own: .visible)
        let tabs = Self.tabs(60, under: window)
        let hosts = tabs.map { node in
            let host = TerminalHostView(mainWork: linklessMainWork())
            host.followAppearance(signals, node: node)
            return host
        }
        system.options.reduceMotion = true
        signals.refreshDisplayOptions()
        #expect(hosts[0].appearanceCalls == 1, "the shown terminal did not repaint")
        #expect(hosts[1...].allSatisfy { $0.appearanceCalls == 0 }, "a hidden workspace's terminal repainted")
        system.options.reduceMotion = false
        signals.refreshDisplayOptions()
        #expect(hosts[1...].allSatisfy { $0.appearanceCalls == 0 })
        tabs[7].set(.visible)
        #expect(hosts[7].appearanceCalls == 1, "a terminal that shows repaints once for the changes it missed")
        withExtendedLifetime((design, tabs)) {}
    }

    @Test func aReduceMotionToggleWithManyWorkspacesRethemesOnlyTheShownPage() {
        let system = System()
        let design = DesignSettings(display: { system.options })
        let signals = design.signals
        let window = VisibilityNode(root: "window", own: .visible)
        let tabs = Self.tabs(12, under: window)
        let pages = tabs.enumerated().map { index, node in
            let page = Self.page("test.appearance.\(index)")
            page.followAppearance(signals, node: node)
            return page
        }
        system.options.reduceMotion = true
        signals.refreshDisplayOptions()
        #expect(pages[0].appearanceCalls == 1, "the shown page did not re-theme")
        #expect(pages[1...].allSatisfy { $0.appearanceCalls == 0 }, "a hidden workspace's page re-themed")
        tabs[3].set(.visible)
        #expect(pages[3].appearanceCalls == 1)
        withExtendedLifetime((design, tabs)) {}
    }

    /// Before the fix the page followed only `.motion`: with the glass mode unchanged (the default
    /// `glass.lens`, or Low Power Mode) a Reduce Transparency flip reached no page, and each kept
    /// its old opaque or see-through background.
    @Test func aReduceTransparencyFlipReachesAPageWhoseGlassModeStays() {
        let system = System()
        let design = DesignSettings(display: { system.options })
        let signals = design.signals
        let node = VisibilityNode(root: "tab", own: .visible)
        let page = Self.page("test.appearance.transparency")
        page.followAppearance(signals, node: node)
        let before = page.appearanceCalls
        system.options.reduceTransparency = true
        signals.refreshDisplayOptions()
        #expect(page.appearanceCalls == before + 1, "a Reduce Transparency flip did not re-theme the page")
        let expected = WebTheme(page.themeTokens, reduceTransparency: true, surface: .internalPage)
        #expect(page.currentTheme().payloadJSON == expected.payloadJSON, "the page's theme does not read the new value")
        withExtendedLifetime((design, node)) {}
    }
}
