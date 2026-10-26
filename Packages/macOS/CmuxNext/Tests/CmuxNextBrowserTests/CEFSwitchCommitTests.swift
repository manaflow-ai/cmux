import AppKit
@testable import CmuxNextBrowser
import Testing

/// p03-rendering-054: a hosted page shows and hides in the switch's own transaction. The switch's turn
/// only shows or hides the view (the page's layer goes with it); the fork hears the page's visibility,
/// the shown tab's activation and the input window's place once, after that commit. A hidden page's
/// frame waits in the app-wide hidden frame list, never per pane. Without Chromium: a fake fork, and
/// the end of the turn and the commit run when the test says.
@MainActor
@Suite struct CEFSwitchCommitTests {
    /// The fork side: every call in order, as `name browser`.
    final class FakeFork {
        private(set) var calls: [String] = []
        var acceptsVisibility = true
        var hasVisibility = true
        var syncs: [Int32] = []
        func clear() { calls = [] }
        var fork: CEFLayerHosting.Fork {
            var setVisibility: ((Int32, CEFLayerHosting.PageVisibility) -> Bool)?
            if hasVisibility {
                setVisibility = { [self] browser, visibility in
                    calls.append("visibility \(browser) \(visibility)")
                    return acceptsVisibility
                }
            }
            return CEFLayerHosting.Fork(
                setLayerHosting: { [self] browser, enabled in
                    calls.append("hosting \(browser) \(enabled)")
                    return enabled ? 7 : 0
                },
                setResizeSync: { [self] _, timeout in
                    syncs.append(timeout)
                    return true
                },
                setVisibility: setVisibility,
                evictFrame: { [self] browser in
                    calls.append("evict \(browser)")
                    return true
                })
        }
    }

    /// The app-wide list: what each page added (locked or not) and removed, and the evictions it holds.
    final class FakeFrames: CEFHiddenFrames {
        private(set) var log: [String] = []
        private var evictions: [ObjectIdentifier: @MainActor () -> Void] = [:]
        func addFrame(_ owner: ObjectIdentifier, locked: Bool, evict: @escaping @MainActor () -> Void) {
            log.append(locked ? "lock" : "keep")
            evictions[owner] = locked ? nil : evict
        }
        func removeFrame(_ owner: ObjectIdentifier) {
            log.append("remove")
            evictions[owner] = nil
        }
        /// Culls every unlocked frame (one page here, so the order does not matter).
        func evictAll() {
            let due = evictions
            evictions = [:]
            for evict in due.values { evict() }
        }
    }

    let fake = FakeFork()
    /// The app-wide list every page here uses (held here: a page holds it weakly).
    let frames = FakeFrames()
    let turn = CEFLayerHostingTests.Turn()
    let commit = CEFLayerHostingTests.Turn()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(view)
    }

    /// A hosted page window for browser 3, every creation step run, its calls cleared.
    func makeHostedPage(withList: Bool = true) -> CEFLayerHosting {
        let turn = turn, commit = commit
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, refreshIntervals: { [] },
                                      afterCommit: { commit.add($0) })
        hosting.view = view
        if withList { hosting.switchCommit.hiddenFrames = frames }
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        commit.end()
        fake.clear()
        return hosting
    }

    @Test func aWorkspaceSwitchMakesNoForkCallInItsTurnAndOneAfterTheCommit() {
        let hosting = makeHostedPage()
        #expect(hosting.showsInSwitchTransaction)
        // Switch away: the content lifecycle hides the page's view; its layer leaves with it in this transaction.
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        turn.end()
        #expect(fake.calls.isEmpty, "no fork call in the switch's turn")
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden"])
        // Switch back: shown in the switch's frame (its kept frame), the fork told after the commit.
        fake.clear()
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        #expect(fake.calls.isEmpty)
        commit.end()
        #expect(fake.calls == ["visibility 3 visible"])
        #expect(hosting.switchCommit.forkCalls == 2)
    }

    @Test func aTurnThatHidesAndShowsThePageAgainMakesNoCall() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.calls.isEmpty)
        #expect(commit.isEmpty)
    }

    @Test func aViewOutOfEveryWindowIsHidden() {
        let hosting = makeHostedPage()
        view.removeFromSuperview()
        hosting.windowDidChange()
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden"])
    }

    /// A tab switch in a hosted pane: the activation waits for the commit, the last show of the turn
    /// wins, and the input window is placed after the page's visibility.
    @Test func aTabSwitchActivatesAfterTheCommitAndTheLastShowWins() {
        let hosting = makeHostedPage()
        var log: [String] = []
        hosting.pageShown(browser: 4)
        hosting.showAfterCommit(activate: { log.append("activate 4") }, place: { log.append("place 4") })
        hosting.pageShown(browser: 5)
        hosting.showAfterCommit(activate: { log.append("activate 5") }, place: { log.append("place 5") })
        #expect(log.isEmpty)
        #expect(fake.calls.isEmpty)
        commit.end()
        #expect(log == ["activate 5", "place 5"])
        #expect(fake.calls.isEmpty, "a tab switch in a shown pane changes no page window visibility")
    }

    @Test func aShowIntoAHiddenPaneActivatesBeforeThePageShows() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        fake.clear()
        var log: [String] = []
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        hosting.showAfterCommit(activate: { log.append("activate \(fake.calls.count)") }, place: { log.append("place \(fake.calls.count)") })
        commit.end()
        // The new tab becomes active while the window is hidden, so only it is shown to Chromium.
        #expect(log == ["activate 0", "place 1"])
        #expect(fake.calls == ["visibility 3 visible"])
    }

    @Test func aChangedResizeDeadlineReachesTheForkAfterTheCommit() {
        var deadline: Int32 = 8
        let turn = turn, commit = commit
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { deadline }, refreshIntervals: { [] },
                                      afterCommit: { commit.add($0) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        commit.end()
        let before = fake.syncs.count
        deadline = 4
        hosting.pageShown(browser: 3)
        #expect(fake.syncs.count == before)
        commit.end()
        #expect(fake.syncs.last == 4)
    }

    @Test func withoutTheForksVisibilityCallTheShowStaysInTheTurn() {
        fake.hasVisibility = false
        let hosting = makeHostedPage()
        #expect(!hosting.showsInSwitchTransaction)
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        #expect(commit.isEmpty)
        #expect(hosting.switchCommit.forkCalls == 0)
    }

    @Test func aRefusedVisibilityIsTriedAgainAtTheNextPass() {
        let hosting = makeHostedPage()
        fake.acceptsVisibility = false
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(hosting.switchCommit.applied == .visible)
        fake.acceptsVisibility = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "visibility 3 hidden"])
        #expect(hosting.switchCommit.applied == .hidden)
    }

    /// Chrome's `DelegatedFrameHost` locks its frame while shown and unlocks it when hidden; the app-wide
    /// list evicts unlocked frames. The page keeps its frame until then, so the next show is instant.
    @Test func aHiddenPagesFrameWaitsInTheListUntilItEvictsIt() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(frames.log == ["keep"])
        #expect(hosting.switchCommit.isFrameKept)
        #expect(fake.calls == ["visibility 3 hidden"])
        frames.evictAll()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3"])
        #expect(!hosting.switchCommit.isFrameKept)
        // A second eviction of the same frame makes no call.
        frames.evictAll()
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(frames.log == ["keep", "lock"])
        #expect(fake.calls == ["visibility 3 hidden", "evict 3", "visibility 3 visible"])
    }

    @Test func aShownPagesFrameIsNeverEvicted() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        commit.end()
        frames.evictAll()
        #expect(!fake.calls.contains("evict 3"))
    }

    @Test func withNoListAHiddenPagesFrameGoesAtOnce() {
        let hosting = makeHostedPage(withList: false)
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3"])
    }

    @Test func aPageThatStopsBeingHostedLeavesTheList() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        hosting.stop()
        #expect(frames.log == ["keep", "remove"])
        #expect(hosting.switchCommit.applied == .visible)
        frames.evictAll()
        #expect(!fake.calls.contains("evict 3"))
    }
}
