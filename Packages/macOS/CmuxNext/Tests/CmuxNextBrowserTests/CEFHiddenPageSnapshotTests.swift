import AppKit
@testable import CmuxNextBrowser
import IOSurface
import Testing

/// A hosted page hidden past its grace holds no layer host and one volatile snapshot,
/// and a show presents the snapshot in the switch's own turn, the live page on its next frame. Without
/// Chromium: a fake fork, a real IOSurface, and the commit and the fork's copy run when the test says.
@MainActor
@Suite struct CEFHiddenPageSnapshotTests {
    /// The fork side: every call in order, as `name browser`; the copy and the next frame wait for the test.
    final class FakeFork {
        private(set) var calls: [String] = []
        var copies = true
        private var copyDone: (@MainActor (IOSurface?) -> Void)?
        private var presented: (@MainActor () -> Void)?
        var fork: CEFLayerHosting.Fork {
            CEFLayerHosting.Fork(
                setLayerHosting: { [self] browser, enabled in
                    calls.append("hosting \(browser) \(enabled)")
                    return enabled ? 7 : 0
                },
                setVisibility: { [self] browser, visibility in
                    calls.append("visibility \(browser) \(visibility)")
                    return true
                },
                evictFrame: { [self] browser in
                    calls.append("evict \(browser)")
                    return true
                },
                copyFrame: copies ? { [self] browser, done in
                    calls.append("copy \(browser)")
                    copyDone = done
                    return true
                } : nil,
                onNextFrame: copies ? { [self] browser, presented in
                    calls.append("next frame \(browser)")
                    self.presented = presented
                    return true
                } : nil)
        }

        func clear() { calls = [] }

        /// The fork's copy comes back on the main thread.
        func finishCopy(_ surface: IOSurface?) {
            copyDone?(surface)
            copyDone = nil
        }

        /// The page window presents its next frame.
        func presentFrame() {
            presented?()
            presented = nil
        }
    }

    /// The app-wide list: holds each hidden page's eviction until the test culls it.
    final class FakeFrames: CEFHiddenFrames {
        private var evictions: [ObjectIdentifier: @MainActor () -> Void] = [:]
        func addFrame(_ owner: ObjectIdentifier, locked: Bool, evict: @escaping @MainActor () -> Void) {
            evictions[owner] = locked ? nil : evict
        }
        func removeFrame(_ owner: ObjectIdentifier) { evictions[owner] = nil }
        /// The grace of every hidden page ends.
        func evictAll() {
            let due = evictions
            evictions = [:]
            for evict in due.values { evict() }
        }
    }

    let fake = FakeFork()
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
    func makeHostedPage() -> CEFLayerHosting {
        let turn = turn, commit = commit
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, refreshIntervals: { [] },
                                      afterCommit: { commit.add($0) })
        hosting.view = view
        hosting.switchCommit.hiddenFrames = frames
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        commit.end()
        fake.clear()
        return hosting
    }

    /// A 400 x 300 BGRA surface standing in for the fork's copy of the page's frame.
    func frameCopy() throws -> IOSurface {
        try #require(IOSurface(properties: [
            .width: 400, .height: 300, .bytesPerElement: 4, .pixelFormat: 0x4247_5241, // 'BGRA'
        ]))
    }

    /// The surface's purgeable state as the kernel keeps it (kIOSurfacePurgeableKeepCurrent reads it).
    func purgeableState(_ surface: IOSurface) -> UInt32 {
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, 3, &old)
        return old
    }

    func hide(_ hosting: CEFLayerHosting) {
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
    }

    func show(_ hosting: CEFLayerHosting) {
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
    }

    /// Hidden, past its grace, with `surface` copied: the state every show test starts from.
    func evicted(_ hosting: CEFLayerHosting, with surface: IOSurface?) {
        hide(hosting)
        frames.evictAll()
        fake.finishCopy(surface)
        fake.clear()
    }

    @Test func pastItsGraceAPageHoldsNoLayerHostAndOneVolatileSnapshot() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        hide(hosting)
        #expect(page.contextID == 7, "within the grace the page keeps its layer host")
        frames.evictAll()
        #expect(hosting.hiddenSnapshot.phase == .capturing)
        #expect(fake.calls == ["visibility 3 hidden", "copy 3"], "the renderer keeps its frame until the copy is back")
        let surface = try frameCopy()
        fake.finishCopy(surface)
        #expect(page.contextID == 0, "no layer host")
        #expect(page.snapshotCover?.snapshot === surface)
        #expect(hosting.hiddenSnapshot.snapshot === surface)
        #expect(hosting.hiddenSnapshot.captures == 1)
        #expect(purgeableState(surface) == 1, "volatile: outside the footprint")
        #expect(hosting.hiddenSnapshot.phase == .evicted)
        #expect(fake.calls == ["visibility 3 hidden", "copy 3", "evict 3"])
    }

    @Test func aShowPresentsTheSnapshotInTheSwitchsTurnAndTheLivePageOnItsNextFrame() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        show(hosting)
        // The switch's turn: the snapshot is on screen with the layer host back under it, no fork call.
        #expect(fake.calls.isEmpty)
        #expect(hosting.hiddenSnapshot.phase == .covering)
        #expect(page.snapshotCover?.snapshot === surface)
        #expect(page.contextID == 7)
        #expect(purgeableState(surface) == 0, "non-volatile while it shows")
        let cover = try #require(page.snapshotCover)
        let coverIndex = try #require(page.subviews.firstIndex(of: cover))
        let surfaceIndex = try #require(page.subviews.firstIndex(of: page.surface))
        #expect(coverIndex > surfaceIndex, "over the live layer")
        commit.end()
        #expect(fake.calls == ["visibility 3 visible", "next frame 3"])
        fake.presentFrame()
        #expect(page.snapshotCover == nil)
        #expect(hosting.hiddenSnapshot.phase == .live)
        #expect(hosting.hiddenSnapshot.snapshot == nil)
    }

    @Test func aPurgedSnapshotShowsThePagesBackground() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, 2, &old) // kIOSurfacePurgeableEmpty: what memory pressure does
        show(hosting)
        #expect(page.snapshotCover == nil)
        #expect(page.contextID == 7)
        #expect(hosting.hiddenSnapshot.phase == .live)
        #expect(hosting.hiddenSnapshot.purged == 1)
        commit.end()
        #expect(fake.calls == ["visibility 3 visible"], "no frame to wait for")
    }

    @Test func aShowBeforeTheCopyIsBackKeepsTheLayerHostAndDropsTheCopy() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        hide(hosting)
        frames.evictAll()
        show(hosting)
        #expect(hosting.hiddenSnapshot.phase == .live)
        let late = try frameCopy()
        fake.finishCopy(late)
        #expect(page.contextID == 7)
        #expect(page.snapshotCover == nil)
        #expect(!fake.calls.contains("evict 3"))
    }

    @Test func withoutTheForksCopyThePageEvictsAndShowsItsBackground() throws {
        fake.copies = false
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        hide(hosting)
        frames.evictAll()
        #expect(page.contextID == 0)
        #expect(page.snapshotCover == nil)
        #expect(hosting.hiddenSnapshot.phase == .evicted)
        #expect(fake.calls == ["visibility 3 hidden", "evict 3"])
        show(hosting)
        #expect(page.contextID == 7)
        #expect(hosting.hiddenSnapshot.phase == .live)
    }

    @Test func anotherTabsPageIsNeverCoveredByTheSnapshot() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        hosting.pageShown(browser: 4)
        show(hosting)
        #expect(page.snapshotCover == nil)
        #expect(page.contextID == 7)
        #expect(hosting.hiddenSnapshot.phase == .live)
    }

    @Test func aTabShownOverTheCoverTakesItAway() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        show(hosting)
        #expect(page.snapshotCover != nil)
        hosting.pageShown(browser: 4)
        #expect(page.snapshotCover == nil)
        #expect(hosting.hiddenSnapshot.phase == .live)
    }

    @Test func hiddenAgainBeforeItsNextFrameTheSnapshotGoesVolatileWithNoNewCopy() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        show(hosting)
        commit.end()
        hide(hosting)
        frames.evictAll()
        #expect(hosting.hiddenSnapshot.phase == .evicted)
        #expect(page.contextID == 0)
        #expect(page.snapshotCover?.snapshot === surface)
        #expect(purgeableState(surface) == 1)
        #expect(!fake.calls.contains("copy 3"))
        // The frame asked for at the earlier show does not take the new snapshot away.
        fake.presentFrame()
        #expect(page.snapshotCover?.snapshot === surface)
    }

    @Test func shownAndHiddenInOneTurnFromPastItsGraceItDropsTheLayerHostAgainWithNoForkCall() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        show(hosting)
        #expect(page.contextID == 7, "the show put the layer host back in its turn")
        hide(hosting)
        #expect(fake.calls.isEmpty, "the renderer's frame is still evicted: nothing to tell the fork")
        #expect(hosting.hiddenSnapshot.phase == .evicted)
        #expect(page.contextID == 0, "no layer host")
        #expect(page.snapshotCover?.snapshot === surface)
        #expect(purgeableState(surface) == 1, "volatile again")
        // The next show still presents the snapshot, then the live page.
        show(hosting)
        commit.end()
        #expect(page.snapshotCover?.snapshot === surface)
        #expect(fake.calls == ["visibility 3 visible", "next frame 3"])
    }

    @Test func shownAndHiddenInOneTurnWhileTheCopyRunsItCopiesAgainAndEvicts() throws {
        let hosting = makeHostedPage()
        let page = try #require(hosting.page)
        hide(hosting)
        frames.evictAll()
        show(hosting)
        #expect(hosting.hiddenSnapshot.phase == .live, "the show dropped the copy")
        hide(hosting)
        #expect(hosting.hiddenSnapshot.phase == .capturing)
        #expect(fake.calls == ["visibility 3 hidden", "copy 3", "copy 3"], "no visibility call, a new copy")
        let surface = try frameCopy()
        fake.finishCopy(surface)
        #expect(page.contextID == 0, "no layer host")
        #expect(page.snapshotCover?.snapshot === surface)
        #expect(purgeableState(surface) == 1)
        #expect(hosting.hiddenSnapshot.phase == .evicted)
        #expect(fake.calls.last == "evict 3", "the renderer's frame goes")
    }

    @Test func aSnapshotHibernationReadsStaysNonVolatileUntilTheReadEnds() async throws {
        let hosting = makeHostedPage()
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        let snapshot = hosting.hiddenSnapshot
        let reading = Task { await snapshot.picture(of: 3) }
        // The reading task runs on the main actor up to its off-main copy, then this test goes on; the
        // copy's return waits for the main actor, so the read runs until this test awaits it.
        await Task.yield()
        try #require(purgeableState(surface) == 0, "the read started")
        show(hosting)
        commit.end()
        hide(hosting)
        frames.evictAll()
        #expect(snapshot.phase == .evicted)
        #expect(hosting.page?.contextID == 0)
        #expect(purgeableState(surface) == 0, "non-volatile while the read runs")
        let picture = await reading.value
        #expect(picture?.width == 400)
        #expect(purgeableState(surface) == 1, "volatile once the read ends")
    }

    @Test func hibernationReadsTheSnapshotAndLeavesItVolatile() async throws {
        let hosting = makeHostedPage()
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        let picture = try #require(await hosting.hiddenSnapshot.picture(of: 3))
        #expect(picture.width == 400 && picture.height == 300)
        #expect(purgeableState(surface) == 1)
        #expect(await hosting.hiddenSnapshot.picture(of: 4) == nil, "another tab's page has no snapshot")
    }

    @Test func aPurgedSnapshotGivesHibernationNoPicture() async throws {
        let hosting = makeHostedPage()
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(surface, 2, &old)
        #expect(await hosting.hiddenSnapshot.picture(of: 3) == nil)
        #expect(hosting.page?.snapshotCover == nil)
        #expect(hosting.hiddenSnapshot.purged == 1)
    }

    @Test func aPageThatStopsBeingHostedDropsItsSnapshot() throws {
        let hosting = makeHostedPage()
        let surface = try frameCopy()
        evicted(hosting, with: surface)
        hosting.stop()
        #expect(hosting.hiddenSnapshot.phase == .live)
        #expect(hosting.hiddenSnapshot.snapshot == nil)
    }
}
