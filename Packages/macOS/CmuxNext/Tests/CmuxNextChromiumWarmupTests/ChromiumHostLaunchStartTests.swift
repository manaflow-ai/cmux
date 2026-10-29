import CmuxNextChromiumWarmup
import Testing

/// With the Chromium Host, the launch starts it where Chrome's visible-first
/// rule puts it (afterFirstFrame for a Chromium page in a shown pane or Chromium as the default engine,
/// afterStartup for a hidden Chromium tab) and never when nothing makes Chromium likely.
@MainActor @Suite struct ChromiumHostLaunchStartTests {
    @Test func aShownChromiumPaneStartsTheHostAfterTheFirstFrame() {
        let start = ChromiumHostLaunchStart(showsChromiumPane: true, defaultIsChromium: false, hasChromiumTab: true)
        #expect(start?.priority == .afterFirstFrame)
        #expect(start?.reason == .restoredTab)
    }

    /// Every new browser tab is a Chromium tab, so the host is warm before the first
    /// Cmd-Shift-L, started right after the first frame, never before it.
    @Test func chromiumAsTheDefaultEngineStartsTheHostAfterTheFirstFrame() {
        let start = ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: true, hasChromiumTab: false)
        #expect(start?.priority == .afterFirstFrame)
        #expect(start?.reason == .launch)
    }

    @Test func aHiddenChromiumTabStartsTheHostAfterStartup() {
        let start = ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: false, hasChromiumTab: true)
        #expect(start?.priority == .afterStartup)
        #expect(start?.reason == .restoredTab)
    }

    @Test func nothingLikelyLeavesTheHostUnspawned() {
        #expect(ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: false, hasChromiumTab: false) == nil)
    }

    /// The walk of every tab runs only when the cheaper reasons do not decide.
    @Test func theTabWalkRunsOnlyWhenNeeded() {
        var walks = 0
        func walk() -> Bool {
            walks += 1
            return true
        }
        _ = ChromiumHostLaunchStart(showsChromiumPane: true, defaultIsChromium: false, hasChromiumTab: walk())
        _ = ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: true, hasChromiumTab: walk())
        #expect(walks == 0)
        _ = ChromiumHostLaunchStart(showsChromiumPane: false, defaultIsChromium: false, hasChromiumTab: walk())
        #expect(walks == 1)
    }
}
