import Foundation
import Testing

@testable import CmuxMobileBrowser

/// Pure nav-state and loading transitions for a browser surface, exercised
/// without a `WKWebView`.
@MainActor
@Suite struct BrowserSurfaceStateTests {
    private func makeState(initialURL: URL? = nil) -> BrowserSurfaceState {
        BrowserSurfaceState(id: .init(rawValue: "test"), initialURL: initialURL)
    }

    @Test func initialURLSeedsAddressAndLoadRequest() {
        let url = URL(string: "https://example.com")!
        let state = makeState(initialURL: url)
        #expect(state.addressText == "https://example.com")
        #expect(state.currentURL == url)
        #expect(state.consumeLoadRequest() == url)
        // Consumed exactly once.
        #expect(state.consumeLoadRequest() == nil)
    }

    @Test func emptyInitialStateHasNoPendingWork() {
        let state = makeState()
        #expect(state.addressText.isEmpty)
        #expect(state.consumeLoadRequest() == nil)
        #expect(state.consumeCommand() == nil)
        #expect(state.isLoading == false)
        #expect(state.canGoBack == false)
        #expect(state.canGoForward == false)
        #expect(state.isAddressEditing == false)
        #expect(state.savedInteractionState == nil)
        #expect(state.contentModePreference == .recommended)
        #expect(state.prefersDesktopSite == false)
    }

    @Test func consumeHelpersAreIdempotentWhenEmpty() {
        // Calling the consumers repeatedly with nothing pending must keep
        // returning nil; the representable calls these on every refresh and they
        // must not churn observable state on no-op refreshes.
        let state = makeState()
        for _ in 0..<3 {
            #expect(state.consumeLoadRequest() == nil)
            #expect(state.consumeCommand() == nil)
        }
    }

    @Test func loadSetsRequestAndAddressAndClearsError() {
        let state = makeState()
        state.navigationDidFail(message: "boom")
        let url = URL(string: "https://cmux.dev")!
        state.load(url)
        #expect(state.addressText == "https://cmux.dev")
        #expect(state.lastErrorMessage == nil)
        #expect(state.savedInteractionState == nil)
        #expect(state.consumeLoadRequest() == url)
    }

    @Test func saveInteractionStateKeepsLatestNonNilSnapshot() {
        let state = makeState()
        let first = Data([1, 2, 3])
        let second = Data([4, 5, 6])

        state.saveInteractionState(first)
        #expect(state.savedInteractionState as? Data == first)

        state.saveInteractionState(nil)
        #expect(state.savedInteractionState as? Data == first)

        state.saveInteractionState(second)
        #expect(state.savedInteractionState as? Data == second)
    }

    @Test func loadClearsSavedInteractionState() {
        let state = makeState()
        state.saveInteractionState(Data([1, 2, 3]))

        state.load(URL(string: "https://cmux.dev")!)

        #expect(state.savedInteractionState == nil)
    }

    @Test func submitAddressResolvesAndRequestsLoad() {
        let state = makeState()
        state.addressText = "example.com"
        let didLoad = state.submitAddress()
        #expect(didLoad)
        #expect(state.consumeLoadRequest()?.host == "example.com")
    }

    @Test func submitAddressReturnsFalseForEmpty() {
        let state = makeState()
        state.addressText = "   "
        #expect(state.submitAddress() == false)
        #expect(state.consumeLoadRequest() == nil)
    }

    @Test func navigationLifecycleTransitions() {
        let state = makeState()

        state.navigationDidStart()
        #expect(state.isLoading)
        #expect(state.estimatedProgress == 0)
        #expect(state.lastErrorMessage == nil)

        state.estimatedProgress = 0.5
        state.navigationDidFinish()
        #expect(state.isLoading == false)
        #expect(state.estimatedProgress == 1)
    }

    @Test func navigationFailureSurfacesMessageAndStopsLoading() {
        let state = makeState()
        state.navigationDidStart()
        state.navigationDidFail(message: "no network")
        #expect(state.isLoading == false)
        #expect(state.estimatedProgress == 0)
        #expect(state.lastErrorMessage == "no network")
    }

    @Test func commandQueueConsumedOnce() {
        let state = makeState()
        state.request(.reload)
        #expect(state.consumeCommand() == .reload)
        #expect(state.consumeCommand() == nil)
    }

    @Test func laterCommandReplacesPendingCommand() {
        let state = makeState()
        state.request(.goBack)
        state.request(.goForward)
        #expect(state.consumeCommand() == .goForward)
    }

    @Test func contentModeDefaultsToRecommended() {
        let state = makeState()
        #expect(state.contentModePreference == .recommended)
        #expect(state.prefersDesktopSite == false)
    }

    @Test func desktopSiteToggleReloadsCurrentPage() {
        let state = makeState(initialURL: URL(string: "https://example.com")!)
        _ = state.consumeLoadRequest()

        state.togglePrefersDesktopSite()

        #expect(state.contentModePreference == .desktop)
        #expect(state.prefersDesktopSite)
        #expect(state.consumeCommand() == .reload)
    }

    @Test func toggleBackForcesMobileNotRecommended() {
        // On iPads the recommended mode is desktop, so "Request Mobile Site"
        // must force .mobile rather than fall back to the device default.
        let state = makeState(initialURL: URL(string: "https://example.com")!)
        _ = state.consumeLoadRequest()

        state.togglePrefersDesktopSite()
        #expect(state.consumeCommand() == .reload)

        state.togglePrefersDesktopSite()

        #expect(state.contentModePreference == .mobile)
        #expect(state.prefersDesktopSite == false)
        #expect(state.consumeCommand() == .reload)
    }

    @Test func desktopSiteToggleBeforeFirstLoadDoesNotDoubleLoad() {
        let state = makeState(initialURL: URL(string: "https://example.com")!)

        state.togglePrefersDesktopSite()

        #expect(state.prefersDesktopSite)
        #expect(state.consumeCommand() == nil)
        #expect(state.consumeLoadRequest()?.absoluteString == "https://example.com")
    }

    @Test func settingSameContentModePreferenceIsNoOp() {
        let state = makeState(initialURL: URL(string: "https://example.com")!)
        _ = state.consumeLoadRequest()

        state.setContentModePreference(.recommended)

        #expect(state.prefersDesktopSite == false)
        #expect(state.consumeCommand() == nil)
    }
}
