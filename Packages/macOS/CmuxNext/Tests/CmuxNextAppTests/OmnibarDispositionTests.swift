import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import Testing

/// Cmd-Return in the address bar opens the typed URL or search in a new
/// background tab, Shift-Cmd-Return in a new foreground tab (Chrome and
/// Safari). The chords are registry actions, so they beat the
/// navigation-tier actions that share them elsewhere (Toggle Pane Zoom,
/// Toggle Checklist Item Complete) only while the address bar has the
/// keyboard.
@MainActor
struct OmnibarDispositionTests {
    typealias M = KeyOwnershipMatrixTests

    /// The matrix services with these actions runnable (no live page here).
    static func services() -> AppServices {
        let services = M.services()
        for id: ActionID in ["omnibar.openInBackgroundTab", "omnibar.openInForegroundTab", "toggleSplitZoom", "toggleBrowserFocusMode"] {
            services.registry.bind(id, invoke: { _ in })
        }
        return services
    }

    static func returnKey(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try KeyInterceptionTests.key("\r", keyCode: 36, flags)
    }

    @Test func returnChordsInTheAddressBarBelongToTheOmnibar() throws {
        let services = Self.services()
        let omnibar = M.Surface(name: "address bar", focus: M.focused(.browser, tab: "b1", target: .addressBar))
        #expect(M.owner(services, try Self.returnKey([.command]), omnibar) == .action("omnibar.openInBackgroundTab"))
        #expect(M.owner(services, try Self.returnKey([.command, .shift]), omnibar) == .action("omnibar.openInForegroundTab"))
        // Option-Cmd-Return stays Browser Focus Mode (system tier).
        #expect(M.owner(services, try Self.returnKey([.command, .option]), omnibar) == .action("toggleBrowserFocusMode"))
    }

    @Test func returnChordsOutsideTheAddressBarKeepTheirActions() throws {
        let services = Self.services()
        let page = M.Surface(name: "page", focus: M.page)
        let terminal = M.Surface(name: "terminal", focus: M.terminal)
        #expect(M.owner(services, try Self.returnKey([.command, .shift]), page) == .action("toggleSplitZoom"))
        #expect(M.owner(services, try Self.returnKey([.command, .shift]), terminal) == .action("toggleSplitZoom"))
    }

    /// A modified commit (`.open`) opens a new tab in the opener's pane on
    /// the opener's engine, and never loads the URL in the current tab.
    @Test func modifiedCommitOpensANewTabOnTheOpenersEngine() async throws {
        let h = try await DefaultChromiumTests().harness(cef: nil, extraTabs: [DefaultChromiumTests.frontendTab(surface: 31, engine: "webkit")])
        let tab = try #require(h.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first { $0.surface == SurfaceID(rawValue: 31) })
        let entry = try #require(h.services.cache.browser(for: tab))
        let url = try #require(URL(string: "https://b.test/"))
        entry.chrome.addressBar.onEvent?(.didEndEditing(.open(url, .newBackgroundTab)))
        await BrowserTabTests.settle { h.recorder.created.count == 1 }
        #expect(h.recorder.created.last?.1 == "https://b.test/")
        #expect(h.recorder.created.last?.2 == .webkit, "the opener's engine")
        #expect(entry.tab.state.url?.host != "b.test", "the current tab keeps its page")

        entry.chrome.addressBar.onEvent?(.didEndEditing(.open(url, .newForegroundTab)))
        await BrowserTabTests.settle { h.recorder.created.count == 2 }
        #expect(h.recorder.created.last?.1 == "https://b.test/")
        h.teardown()
    }
}
