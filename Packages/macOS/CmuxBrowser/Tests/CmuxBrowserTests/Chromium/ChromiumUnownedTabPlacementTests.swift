import Foundation
import Testing

@testable import CmuxBrowser

/// Where a tab Chromium opens for no cmux page (an extension's
/// `chrome.tabs.create` from its background worker, the welcome page after
/// an install) lands in the active workspace.
@Suite struct ChromiumUnownedTabPlacementTests {
    private typealias Candidate = ChromiumUnownedTabCandidate
    private typealias Placement = ChromiumUnownedTabPlacement

    private let profile = UUID()
    private let otherProfile = UUID()

    private func candidate(
        _ panel: UUID = UUID(), pane: UUID = UUID(), profile: UUID? = nil, chromium: Bool = true,
        focused: Bool = false, selected: Bool = true
    ) -> Candidate {
        Candidate(panelID: panel, paneID: pane, profileID: profile ?? self.profile, isChromium: chromium,
                  isFocused: focused, isSelectedInPane: selected)
    }

    @Test func theFocusedChromiumPageTakesTheTab() {
        let shown = candidate()
        let focused = candidate(focused: true)
        #expect(Placement.anchor(among: [shown, focused], profile: profile) == focused.panelID)
    }

    @Test func aShownChromiumPageTakesItWhenNoneIsFocused() {
        let hidden = candidate(selected: false)
        let shown = candidate()
        #expect(Placement.anchor(among: [hidden, shown], profile: profile) == shown.panelID)
    }

    @Test func onlyAPageOfTheRequestsProfileTakesIt() {
        let focusedOther = candidate(profile: otherProfile, focused: true)
        let shown = candidate()
        #expect(Placement.anchor(among: [focusedOther, shown], profile: profile) == shown.panelID)
        #expect(Placement.anchor(among: [focusedOther], profile: profile) == nil)
        // A request without a known profile (a download) takes the focused page.
        #expect(Placement.anchor(among: [shown, focusedOther], profile: nil) == focusedOther.panelID)
    }

    @Test func webKitPagesNeverTakeIt() {
        #expect(Placement.anchor(among: [candidate(chromium: false, focused: true)], profile: profile) == nil)
    }

    /// Without a Chromium page to join, the tab opens in the focused browser
    /// pane (any engine), else a shown browser pane, else a new pane.
    @Test func withoutAnAnchorItOpensInABrowserPane() {
        let webkitFocused = candidate(chromium: false, focused: true)
        let shown = candidate(profile: otherProfile)
        #expect(Placement.pane(among: [shown, webkitFocused]) == webkitFocused.paneID)
        #expect(Placement.pane(among: [candidate(selected: false), shown]) == shown.paneID)
        #expect(Placement.pane(among: [candidate(selected: false)]) == nil)
        #expect(Placement.pane(among: []) == nil)
    }

    /// A foreground tab nobody clicked for (an extension's tab, a script's
    /// `window.open`) is selected in its pane but takes the keyboard only
    /// when that pane already has it: it never pulls focus out of a terminal.
    @Test func aTabNobodyClickedForNeverTakesTheKeyboardFromAnotherPane() {
        #expect(Placement.newTabFocus(foreground: true, userGesture: true) == .focus)
        #expect(Placement.newTabFocus(foreground: true, userGesture: false) == .selectFocusingOnlyAFocusedPane)
        #expect(Placement.newTabFocus(foreground: false, userGesture: true) == .background)
        #expect(Placement.newTabFocus(foreground: false, userGesture: false) == .background)
    }
}
