import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
private final class FakeBrowserActing: ReactGrabBrowserActing {
    let id: UUID
    var armedReturn: UUID??
    var clearedReason: String?
    var requestFocusResult: Bool
    private(set) var requestFocusCallCount = 0

    init(id: UUID, requestFocusResult: Bool = true) {
        self.id = id
        self.requestFocusResult = requestFocusResult
    }

    func armReactGrabRoundTrip(returnTo panelId: UUID) { armedReturn = .some(panelId) }
    func clearReactGrabRoundTrip(reason: String) { clearedReason = reason }

    @discardableResult
    func requestExplicitWebViewFocus() -> Bool {
        requestFocusCallCount += 1
        return requestFocusResult
    }

    func ensureReactGrabActive() async {}
    func toggleOrInjectReactGrab() async {}
}

@MainActor
private final class FakeWorkspace: ReactGrabWorkspaceContext {
    let reactGrabWorkspaceId = UUID()
    var reactGrabFocusedPanelId: UUID?
    var route: ReactGrabRoute?
    var browsers: [UUID: FakeBrowserActing] = [:]
    var terminals: Set<UUID> = []
    private(set) var clearSplitZoomCount = 0
    private(set) var focusedPanels: [UUID] = []

    func reactGrabRouteFromFocus() -> ReactGrabRoute? { route }

    func reactGrabBrowserActing(for panelId: UUID) -> (any ReactGrabBrowserActing)? {
        browsers[panelId]
    }

    func reactGrabPanelIsTerminal(_ panelId: UUID) -> Bool { terminals.contains(panelId) }

    func reactGrabClearSplitZoom() { clearSplitZoomCount += 1 }

    func reactGrabFocusPanel(_ panelId: UUID) { focusedPanels.append(panelId) }
}

@MainActor
@Suite struct ReactGrabControllerTests {
    /// With no explicit ids and a focused-terminal route, the controller arms
    /// the route's return terminal, focuses the browser, and reports it.
    @Test func routeWithReturnTerminalArmsAndActs() {
        let controller = ReactGrabController()
        let ws = FakeWorkspace()
        let browserId = UUID()
        let terminalId = UUID()
        let browser = FakeBrowserActing(id: browserId)
        ws.browsers[browserId] = browser
        ws.terminals = [terminalId]
        ws.route = ReactGrabRoute(browserPanelId: browserId, returnTerminalPanelId: terminalId)
        ws.reactGrabFocusedPanelId = terminalId

        let acted = controller.toggleReactGrab(in: ws, browserSurfaceId: nil, returnTerminalSurfaceId: nil)

        #expect(acted == browserId)
        #expect(browser.armedReturn == .some(terminalId))
        #expect(ws.clearSplitZoomCount == 1)
        #expect(ws.focusedPanels == [browserId])
        #expect(browser.requestFocusCallCount == 1)
    }

    /// A focused-browser route (no return terminal) clears the round-trip.
    @Test func routeWithoutReturnTerminalClearsRoundTrip() {
        let controller = ReactGrabController()
        let ws = FakeWorkspace()
        let browserId = UUID()
        let browser = FakeBrowserActing(id: browserId)
        ws.browsers[browserId] = browser
        ws.route = ReactGrabRoute(browserPanelId: browserId, returnTerminalPanelId: nil)
        ws.reactGrabFocusedPanelId = browserId

        let acted = controller.toggleReactGrab(in: ws, browserSurfaceId: nil, returnTerminalSurfaceId: nil)

        #expect(acted == browserId)
        #expect(browser.clearedReason == "shortcut.noReturnTarget")
        // Browser already focused: no zoom clear / re-focus.
        #expect(ws.clearSplitZoomCount == 0)
        #expect(ws.focusedPanels.isEmpty)
    }

    /// An explicit non-browser surface fails resolution.
    @Test func explicitNonBrowserSurfaceReturnsNil() {
        let controller = ReactGrabController()
        let ws = FakeWorkspace()
        let acted = controller.toggleReactGrab(
            in: ws,
            browserSurfaceId: UUID(),
            returnTerminalSurfaceId: nil
        )
        #expect(acted == nil)
    }

    /// An explicit non-terminal return surface fails resolution.
    @Test func explicitNonTerminalReturnReturnsNil() {
        let controller = ReactGrabController()
        let ws = FakeWorkspace()
        let browserId = UUID()
        ws.browsers[browserId] = FakeBrowserActing(id: browserId)
        let acted = controller.toggleReactGrab(
            in: ws,
            browserSurfaceId: browserId,
            returnTerminalSurfaceId: UUID()
        )
        #expect(acted == nil)
    }

    /// An explicit browser surface with no explicit return does not adopt the
    /// route's terminal (it clears the round-trip instead).
    @Test func explicitBrowserDoesNotAdoptRouteReturnTerminal() {
        let controller = ReactGrabController()
        let ws = FakeWorkspace()
        let browserId = UUID()
        let terminalId = UUID()
        let browser = FakeBrowserActing(id: browserId)
        ws.browsers[browserId] = browser
        ws.terminals = [terminalId]
        // Route would suggest a return terminal, but an explicit browser was given.
        ws.route = ReactGrabRoute(browserPanelId: browserId, returnTerminalPanelId: terminalId)

        let acted = controller.toggleReactGrab(
            in: ws,
            browserSurfaceId: browserId,
            returnTerminalSurfaceId: nil
        )

        #expect(acted == browserId)
        #expect(browser.clearedReason == "shortcut.noReturnTarget")
        #expect(browser.armedReturn == nil)
    }

    /// No route and no explicit browser yields nil.
    @Test func noRouteReturnsNil() {
        let controller = ReactGrabController()
        let ws = FakeWorkspace()
        let acted = controller.toggleReactGrab(in: ws, browserSurfaceId: nil, returnTerminalSurfaceId: nil)
        #expect(acted == nil)
    }
}
