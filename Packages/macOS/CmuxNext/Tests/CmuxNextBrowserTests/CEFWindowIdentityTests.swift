import Testing
@testable import CmuxNextBrowser

/// Bug: a target=_blank tab from an incognito window's page opened in the
/// normal window's pane. Chromium reports a popup with window 0 (it is in
/// no window yet), and a pane host whose window id read 0 at creation
/// "owned" window 0, so it adopted every such popup, of any store.
@Suite struct CEFWindowIdentityTests {
    @Test func windowZeroNamesNoHost() {
        #expect(!CEFWindowIdentity.owns(recorded: 0, reported: 0, liveWindowIDs: { [0] }))
        #expect(!CEFWindowIdentity.owns(recorded: nil, reported: 0, liveWindowIDs: { [] }))
    }

    /// A host whose window id was not known at creation still owns the
    /// window its tabs are in.
    @Test func theLiveWindowOfTheHostsTabsCounts() {
        #expect(CEFWindowIdentity.owns(recorded: 0, reported: 7, liveWindowIDs: { [7] }))
        #expect(CEFWindowIdentity.owns(recorded: 5, reported: 5, liveWindowIDs: { [] }))
        #expect(!CEFWindowIdentity.owns(recorded: 5, reported: 7, liveWindowIDs: { [5] }))
    }
}
