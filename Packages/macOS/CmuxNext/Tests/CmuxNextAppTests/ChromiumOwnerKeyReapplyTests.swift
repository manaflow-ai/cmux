import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextTabs
import Observation
import Testing

/// CMUX-655: an owner-window mouse-down leaves the selected Chromium page recorded as focused.
/// Reapplying that same target must grant its page again when the owner holds the keys. This runs
/// the real pane, focus coordinator and effect applier; only the engine and key-window source are
/// doubles, since the app fixture deliberately never makes its windows key.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChromiumOwnerKeyReapplyTests {
    @Test func theSamePresentedPageRegainsFocusWhenItsOwnerHasTheKeys() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let content = try #require(controller.workspaceContent)
            let pane = try #require(content.focusedPane)
            let previousKeySource = services.keyWindowSource
            services.keyWindowSource = { nil }
            defer { services.keyWindowSource = previousKeySource }

            let created = try await connection.newFrontendBrowserTab(url: "about:blank", engine: .webkit, in: pane.pane.handle, activate: false)
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: created.surface) != nil })
            let browser = try #require(services.daemon.store.tab(surface: created.surface)?.id)
            try await PinnedPageTests.until({ pane.pane.tabs.contains { $0.id == browser } })
            try #require(services.cache.existingBrowser(browser) == nil, "the unselected tab already made its page")
            let page = ChildWindowPage(configuration: BrowserTabConfiguration(id: BrowserTabID(rawValue: browser)))
            services.cache.install(page, for: browser)
            pane.select(TabID(browser))
            PaneHandlers.focus(pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({
                controller.focus.state.resolved == .browserPage(pane: pane.paneKey, tab: browser)
                    && controller.focusApplier.focusedChildWindowPageID == browser
                    && page.focusGrants > 0
            }, report: { "the child-window page was never presented and focused" })
            let grants = page.focusGrants
            let blurs = page.focusBlurs

            // The state after keysReturned ignores a mouse-down: the owner has the keys, while
            // the applier still records this exact page. No notification clears that record.
            services.keyWindowSource = { window }
            try #require(controller.focusApplier.focusedChildWindowPageID == browser)
            // A successful engine grant takes the keys out of the owner. A subsequent reapply
            // must therefore be idempotent, just as it is when Chromium's child becomes key.
            page.onGrant = { services.keyWindowSource = { nil } }
            controller.focus.send(.contentPresented(pane: pane.paneKey))
            #expect(page.focusGrants == grants + 1, "the owner retained the keys because the applier treated recorded focus as actual page focus")
            #expect(page.focusBlurs == blurs, "the same page was blurred before its regrant")
            #expect(controller.focusApplier.focusedChildWindowPageID == browser)

            controller.focus.send(.contentPresented(pane: pane.paneKey))
            #expect(page.focusGrants == grants + 1, "a settled page was granted repeatedly")
        }
    }

    /// MockBrowserTab is intentionally in-view. Forward its engine behavior but present this
    /// page as a child window, so the regression goes through FocusEffectApplier's Chromium arm.
    @Observable @MainActor private final class ChildWindowPage: BrowserTab {
        private let backing: MockBrowserTab
        @ObservationIgnored var onGrant: (() -> Void)?
        @ObservationIgnored private(set) var focusGrants = 0
        @ObservationIgnored private(set) var focusBlurs = 0

        init(configuration: BrowserTabConfiguration) {
            backing = MockBrowserEngine(kind: .cef).makeMockTab(configuration)
        }

        var id: BrowserTabID { backing.id }
        var engineKind: BrowserEngineKind { .cef }
        var profileID: BrowserProfileID { backing.profileID }
        var presentation: BrowserPresentation { .childWindow }
        var contentView: NSView { backing.contentView }
        var state: BrowserTabState { backing.state }
        var favicon: NSImage? { backing.favicon }
        var pendingPrompts: [BrowserPrompt] { backing.pendingPrompts }
        var linkStatus: String? { backing.linkStatus }
        var delegate: (any BrowserTabDelegate)? {
            get { backing.delegate }
            set { backing.delegate = newValue }
        }
        var keyRouter: (any BrowserKeyRouting)? {
            get { backing.keyRouter }
            set { backing.keyRouter = newValue }
        }

        func load(_ url: URL) { backing.load(url) }
        func goBack() { backing.goBack() }
        func goForward() { backing.goForward() }
        func reload() { backing.reload() }
        func stop() { backing.stop() }
        func setFocused(_ focused: Bool) {
            backing.setFocused(focused)
            if focused { focusGrants += 1; onGrant?() } else { focusBlurs += 1 }
        }
        func setContentVisible(_ visible: Bool) { backing.setContentVisible(visible) }
        func snapshot() async throws -> CGImage { try await backing.snapshot() }
        func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
            try await backing.evaluate(script, world: world, gesture: gesture)
        }
        func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
            await backing.find(text, direction: direction, caseSensitive: caseSensitive)
        }
        func clearFind() { backing.clearFind() }
        func setZoom(_ zoom: Double) { backing.setZoom(zoom) }
        func exitContentFullscreen() { backing.exitContentFullscreen() }
        func showDevTools() { backing.showDevTools() }
        func close() { onGrant = nil; backing.close() }
    }
}
