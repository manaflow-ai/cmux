import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextHistory
import CmuxNextInputCore
@testable import CmuxNextRemoteBrowser
@testable import CmuxNextRemoteView
@testable import CmuxNextRemoteViewSessions
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import CoreVideo
import Foundation
import Testing

#if DEBUG
/// Remote view tabs under Memory Saver (feature `memoryDiscardRemoteTabs`). A
/// hidden remote browser tab went on decoding its stream (only the host was told it hid), its
/// popups decoded theirs, and no remote tab could be discarded: none was a
/// `BrowserHibernationSource`, so each kept its stream, decoder and presenter for as long as it
/// lived. Now hiding pauses every decode in the same turn, a tab hidden past the timeout (or at
/// critical pressure) becomes a hibernated tab holding its last frame, and showing it builds the
/// tab again from its record through the cmux page wake (`restoreAppPage`), under that frame until
/// the new stream's first one. A session the person stopped is never discarded: a wake would
/// connect again. The host is the VideoToolbox mock desktop behind a counting source; the remote
/// browser session is a fake channel.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct RemoteTabDiscardTests {
    // MARK: Hide

    @Test func hidingARemoteBrowserTabStopsItsFramesInTheSameTurn() async throws {
        let stream = try RemoteStream()
        defer { stream.close() }
        stream.tab.setContentVisible(true)
        try await Self.until("a frame shows") { stream.damage(); return stream.presenter.presented > 0 }

        stream.tab.setContentVisible(false)
        #expect(!stream.tab.pane.isDecoding, "the hidden tab still decodes")
        #expect(stream.channel.visible.last == false, "the host was not told the tab hid")
        let shown = stream.presenter.presented
        let sent = stream.source.sent
        try await Self.until("the host sent three more frames") { stream.damage(); return stream.source.sent >= sent + 3 }
        #expect(stream.presenter.presented == shown, "a hidden tab presented frames")

        stream.tab.setContentVisible(true)
        try await Self.until("shown again, it streams") { stream.damage(); return stream.presenter.presented > shown }
    }

    /// The desktop pane's stop cancelled its tasks only: a frame whose decode had started before the
    /// stop came out after it and went on screen in the hidden tab. The decode here is held open
    /// across the stop and answers after it, as a slow hardware decode does.
    @Test func aFrameDecodedAcrossTheDesktopPanesStopNeverShows() async throws {
        let source = HeldFrameSource()
        let pane = RemoteDesktopPane(hostName: RemoteViewPageSession.mockHost, source: source, inputSink: nil,
                                     mainWork: MainWorkScheduler(budget: MainFrameBudget()), presenter: .layerContents)
        pane.start()
        try await Self.until("the pane asks for a frame") { source.asked == 1 }
        let first = try #require(Self.decodedFrame(1))
        let late = try #require(Self.decodedFrame(2))
        source.hand(first)
        try await Self.until("the first frame shows") { pane.lastFrame?.frame == 1 }
        try await Self.until("the pane decodes the next frame") { source.asked == 2 }

        pane.stop()
        source.hand(late)
        // The late frame would reach the screen within a few main-actor turns.
        try await Task.sleep(for: .milliseconds(300))
        #expect(pane.lastFrame?.frame == 1, "a frame decoded before the stop showed after it")
    }

    @Test func hidingARemoteBrowserPagePausesItsPopups() throws {
        let host = MockRemoteStreamSource(width: 160, height: 100)
        try #require(host.canEncode, "VideoToolbox has no H.264 encoder here")
        let source = CountingSource(host: host)
        let surfaces = RemoteBrowserSurfaces(page: RemoteBrowserContentView(), source: { _ in source }, send: { _, _ in },
                                             mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { surfaces.closeAll() }
        let anchor = CGRect(x: 0, y: 0, width: 160, height: 100)
        surfaces.apply(.show(surface: 1, stream: 2, kind: "autofill", anchor: anchor, pixelWidth: 160, pixelHeight: 100))
        #expect(surfaces.isDecoding(1))

        surfaces.setVisible(false)
        #expect(!surfaces.isDecoding(1), "a hidden page's popup still decodes")
        surfaces.apply(.show(surface: 3, stream: 4, kind: "page_popup", anchor: anchor, pixelWidth: 160, pixelHeight: 100))
        #expect(!surfaces.isDecoding(3), "a popup opened while the page is hidden decodes")

        surfaces.setVisible(true)
        #expect(surfaces.isDecoding(1) && surfaces.isDecoding(3), "shown again, the popups do not decode")
    }

    // MARK: Discard

    @Test func aHiddenRemoteBrowserTabIsDiscardedToItsLastFrameAndItsDecoderGoes() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        rig.hibernation.discardsStreamedPages = true
        let address = try #require(URL(string: "cmux://remote-browser?address=127.0.0.1:9"))
        let hidden = try await Self.showThenHide(in: rig, wakeRecord: address)
        defer { hidden.pump.cancel() }
        // The rig is at critical pressure: a page hidden 10 s goes, with no page probe to answer.
        try await rig.until("the tab was discarded") { rig.isHibernated(hidden.key) || rig.exemption(hidden.key) != nil }
        try #require(rig.isHibernated(hidden.key), "kept: \(String(describing: rig.exemption(hidden.key)))")

        try await rig.until("the stream's tab, pane and decoder went") { hidden.tab == nil && hidden.pane == nil }
        let asleep = try #require(rig.services.cache.browsers[hidden.key]?.tab as? HibernatedBrowserTab)
        #expect(asleep.restoreState == .appPage(BrowserAppPageState(url: address)))
        let picture = try #require(asleep.snapshotImage, "the hibernated tab has no last frame")
        #expect(picture.width == hidden.pictureWidth, "the picture is not the pane's own size")
    }

    @Test func withTheFeatureOffARemoteTabIsNotDiscarded() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let address = try #require(URL(string: "cmux://remote-browser?address=127.0.0.1:9"))
        let hidden = try await Self.showThenHide(in: rig, wakeRecord: address)
        defer { hidden.pump.cancel() }
        #expect(rig.hibernation.hibernateNow(hidden.key) != nil, "the person's Hibernate Tab discarded a remote tab with the feature off")
        #expect(!rig.isHibernated(hidden.key))
    }

    /// A streaming desktop goes to sleep holding its last frame, its session and pane go, and
    /// showing it builds it again through the cmux page wake, which connects: the last frame covers
    /// the new pane from the swap's own turn, and its first frame takes it away.
    @Test func aStreamingDesktopIsDiscardedAndShowsAgainUnderItsLastFrame() async throws {
        try #require(MockRemoteStreamSource(width: 64, height: 64).canEncode, "VideoToolbox has no H.264 encoder here")
        let rig = PageBrowserTabDiscardTests.Rig(path: .pressure)
        defer { rig.close() }
        rig.hibernation.discardsStreamedPages = true
        // The cap never runs out here: only the new stream's first frame removes the picture.
        rig.hibernation.standInClock = ManualClock()
        let record = try #require(RemoteViewTabRecord(host: RemoteViewPageSession.mockHost))
        let key: String
        weak var oldTab: RemoteViewPageTab?
        weak var oldSession: RemoteViewPageSession?
        weak var oldPane: RemoteDesktopPane?
        do {
            let opened = try Self.connectedDesktop(rig, record: record)
            key = opened.key
            oldTab = opened.tab
            oldSession = opened.session
            oldPane = opened.session.pane
            try await Self.until("the desktop shows a frame") { opened.session.pane.lastFrame != nil }
        }
        let frameWidth = try #require(oldPane?.lastFrame?.pixelSize.width)
        #expect(frameWidth > 0)

        rig.hide(key)
        #expect(rig.hibernation.hibernateNow(key) == nil, "the person's Hibernate Tab kept a streaming desktop")
        try await Self.until("the desktop was discarded") { rig.isHibernated(key) }
        try await Self.until("its tab, session and pane went") { oldTab == nil && oldSession == nil && oldPane == nil }
        let asleep = try #require(rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)
        #expect(asleep.restoreState == .appPage(BrowserAppPageState(url: record.url)))
        let window = Self.window()
        defer { window.close() }
        window.contentView = asleep.contentView
        try await Self.until("the placeholder shows the last frame") { asleep.shownPicture != nil }
        let shown = try #require(asleep.shownPicture)

        var atSwap: (pixels: CGImage?, presented: Bool)?
        let previous = rig.services.cache.onBrowserReady
        rig.services.cache.onBrowserReady = { [weak cache = rig.services.cache] ready in
            previous?(ready)
            guard ready == key, atSwap == nil, let woken = cache?.browsers[ready]?.tab as? RemoteViewPageTab else { return }
            atSwap = (woken.wakeCoverPixels, woken.debugSession?.pane.lastFrame != nil)
        }
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await Self.until("the desktop was built again") { atSwap != nil }
        let pixels = try #require(atSwap?.pixels, "the new pane had no last frame over it in the swap's own turn")
        #expect(pixels.width == shown.width && pixels.height == shown.height, "the cover is not the placeholder's picture")
        #expect(atSwap?.presented == false)

        let woken = try #require(rig.services.cache.browsers[key]?.tab as? RemoteViewPageTab)
        window.contentView = woken.contentView
        woken.setContentVisible(true)
        try await Self.until("the new stream's first frame took the last frame away") { !woken.showsWakeCover }
        #expect(woken.debugSession?.pane.lastFrame != nil)
    }

    /// The person pressed Stop: the ended card and the last frame stay until the pane's Reconnect.
    /// A discard would have built the tab again on show and connected (in control mode, taking the
    /// remote machine again), so a stopped desktop is never discarded.
    @Test func aDesktopThePersonStoppedIsNotDiscarded() async throws {
        try #require(MockRemoteStreamSource(width: 64, height: 64).canEncode, "VideoToolbox has no H.264 encoder here")
        let rig = PageBrowserTabDiscardTests.Rig(path: .pressure)
        defer { rig.close() }
        rig.hibernation.discardsStreamedPages = true
        let record = try #require(RemoteViewTabRecord(host: RemoteViewPageSession.mockHost))
        let opened = try Self.connectedDesktop(rig, record: record)
        try await Self.until("the desktop shows a frame") { opened.session.pane.lastFrame != nil }
        #expect(opened.tab.supportsHibernation)

        opened.session.pane.view.toolbar.onStop?()
        #expect(opened.session.isEnded)
        #expect(opened.tab.wakeAddress == nil, "a stopped desktop can be built again")
        rig.hide(opened.key)
        #expect(rig.hibernation.hibernateNow(opened.key) != nil, "a stopped desktop was discarded")
        #expect(!rig.isHibernated(opened.key))
        rig.services.cache.present(opened.key, by: rig.pane, presence: .visible)
        #expect(rig.services.cache.browsers[opened.key]?.tab === opened.tab, "showing the stopped desktop built a new session")
    }

    // MARK: The last frame

    /// A woken stream connects again (transport, the host's open, a keyframe) before its first
    /// frame: a paint's 500 ms cap took its picture away first and showed the connecting pane.
    @Test func aWokenStreamKeepsItsLastFrameLongerThanAPaintsCap() async throws {
        let stream = try RemoteStream()
        defer { stream.close() }
        let clock = ManualClock()
        let cap = try #require(stream.tab.wakeCoverCap)
        #expect(cap > BrowserHibernation.standInCap)
        let picture = try #require(Self.picture())
        #expect(stream.tab.showStandIn(picture, decoded: true, cap: cap, clock: clock))
        #expect(stream.tab.wakeCoverPixels != nil, "the cover has no pixels in its first frame")
        try await clock.waitForSleeper()
        clock.advance(by: BrowserHibernation.standInCap + .milliseconds(200))
        try await Task.sleep(for: .milliseconds(100))
        #expect(stream.tab.showsWakeCover, "the last frame went at a paint's cap, before the stream's first frame")

        stream.tab.setContentVisible(true)
        try await Self.until("the stream's first frame took the last frame away") { stream.damage(); return !stream.tab.showsWakeCover }
    }

    @Test func aWokenStreamWithNoFrameDropsItsLastFrameAtTheReconnectCap() async throws {
        let stream = try RemoteStream()
        defer { stream.close() }
        let clock = ManualClock()
        let cap = try #require(stream.tab.wakeCoverCap)
        let picture = try #require(Self.picture())
        stream.tab.showStandIn(picture, decoded: false, cap: cap, clock: clock)
        try await clock.waitForSleeper()
        clock.advance(by: cap)
        try await Self.until("the last frame went at the cap") { !stream.tab.showsWakeCover }
    }

    /// The picture is the pane as drawn, with the stream's frame in its video: same size as the
    /// pane, so the placeholder and the wake cover line up with it.
    @Test func aStreamingTabsPictureIsThePaneWithItsFrame() async throws {
        let stream = try RemoteStream()
        defer { stream.close() }
        stream.tab.contentView.frame = NSRect(x: 0, y: 0, width: 160, height: 100)
        stream.tab.setContentVisible(true)
        try await Self.until("a frame shows") { stream.damage(); return stream.tab.pane.lastFrame != nil }
        let picture = try await stream.tab.snapshot()
        #expect(picture.width == Self.bitmapWidth(of: stream.tab.contentView))
    }

    /// A failed tab's picture is its message (the snapshot failed for a tab with no frame).
    @Test func aFailedRemoteBrowserTabsPictureIsItsMessage() async throws {
        let stream = try RemoteStream()
        defer { stream.close() }
        stream.tab.contentView.frame = NSRect(x: 0, y: 0, width: 160, height: 100)
        stream.tab.makeWakeRecord()
        stream.tab.showFailure(.unreachable, message: "Not reachable")
        let picture = try await stream.tab.snapshot()
        #expect(picture.width == Self.bitmapWidth(of: stream.tab.contentView))
        #expect(!stream.tab.supportsHibernation, "a failed tab can be discarded")
    }

    // MARK: What may go

    /// A new connection starts a new remote runtime: a page with back or forward history would
    /// lose it, so it stays; a tab with no record (its host ends with it) never goes.
    @Test func aRemotePageWithHistoryIsNotDiscarded() throws {
        let stream = try RemoteStream()
        defer { stream.close() }
        #expect(!stream.tab.supportsHibernation, "a tab with no record can be discarded")
        let address = stream.tab.makeWakeRecord()
        #expect(stream.tab.supportsHibernation)
        #expect(stream.tab.hibernationState() == .appPage(BrowserAppPageState(url: address)))
        // Duplicate and Reopen Closed Tab open the address; it is no engine history.
        #expect(BrowserRestoreState.history(of: stream.tab) == nil)

        stream.tab.applyPage(url: URL(string: "https://example.com/next"), title: "Next", loading: false, canGoBack: true, canGoForward: false)
        #expect(!stream.tab.supportsHibernation, "a remote page with back history can be discarded")
        #expect(stream.tab.hibernationState() == nil)
    }

    // MARK: A machine's browser

    /// A woken streamed page's last frame stays over the machine's not-ready page while the machine's browser
    /// starts, and the streamed page takes it over; a page that says why the browser is not there shows that.
    @Test func aMachinesNotReadyPageHandsTheLastFrameToItsStream() throws {
        let page = Self.machinePage()
        #expect(page.drawsInFirstFrame, "a not-ready page waits for a picture to cover its message")
        let picture = try #require(Self.picture())
        #expect(!page.showStandIn(picture, decoded: true, cap: BrowserWakeCover.reconnectCap, clock: ManualClock()),
                "a page that says why the browser is not there showed an old frame")
        page.phase = .starting("m1")
        #expect(!page.drawsInFirstFrame, "a starting page's wake shows no last frame")
        #expect(page.showStandIn(picture, decoded: true, cap: BrowserWakeCover.reconnectCap, clock: ManualClock()))

        let stream = try RemoteStream()
        defer { stream.close() }
        page.handOverWakeCover(to: stream.tab)
        #expect(!page.showsWakeCover)
        #expect(stream.tab.wakeCoverPixels != nil, "the streamed page did not take the last frame over")
    }

    /// A machine's not-ready page hidden past its discard rule was held until its tab closed: it was no
    /// `BrowserHibernationSource`, so the planner could never release it. Now it goes through the same
    /// cmux page discard as History or Bookmarks (`memoryDiscardPageTabs`): it hibernates to its record
    /// with the address the person typed, and a show builds the not-ready page again from that record.
    @Test func aHiddenMachineTabPastItsDiscardRuleIsReleasedAndWakesWithItsAddress() async throws {
        let rig = PageBrowserTabDiscardTests.Rig(path: .pressure)
        defer { rig.close() }
        let typed = try #require(URL(string: "https://example.com/typed"))
        let record = MachineBrowserRecord(machine: "m1", initialURL: try #require(URL(string: "https://example.com/")))
        let key: String
        weak var oldPage: MachineBrowserPageTab?
        do {
            let (opened, page) = try rig.open(record.url)
            key = opened
            let machinePage = try #require(page as? MachineBrowserPageTab, "the record made no machine page")
            machinePage.load(typed)
            oldPage = machinePage
        }
        rig.hide(key)
        try await rig.until("the hidden machine tab was released") { rig.isHibernated(key) }
        let asleep = try #require(rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)
        #expect(asleep.restoreState == .appPage(BrowserAppPageState(url: MachineBrowserRecord(machine: "m1", initialURL: typed).url)),
                "the released tab forgot the address the person typed")
        await rig.nextRunLoopTurn()
        #expect(oldPage == nil, "the machine page outlived its release")

        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the machine tab woke") { !rig.isHibernated(key) }
        let woken = try #require(rig.services.cache.browsers[key]?.tab as? MachineBrowserPageTab, "the wake made no machine page")
        #expect(woken.queuedURL == typed, "the woken page lost the typed address")
        #expect(woken.record.machine == "m1")
    }

    @Test func aMachinesBrowserThatFailsToStartDropsTheLastFrame() throws {
        let page = Self.machinePage()
        page.phase = .starting("m1")
        let picture = try #require(Self.picture())
        page.showStandIn(picture, decoded: true, cap: BrowserWakeCover.reconnectCap, clock: ManualClock())
        page.phase = .failed("m1", "no runtime")
        #expect(!page.showsWakeCover, "a failed start kept the last frame over its reason")
    }

    /// A machine's streamed tab that hibernated closed its session, which forgot that the tab runs
    /// on the machine: the placeholder then said it ran on this Mac.
    @Test func aHibernatedMachineTabSaysNoThisMacChip() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let page = URL(string: "https://example.com/")
        let onMachine = Self.placeholder(.appPage(BrowserAppPageState(url: MachineBrowserRecord(machine: "m1", initialURL: page).url)))
        rig.keys.append(onMachine.id.rawValue)
        #expect(rig.services.cache.install(onMachine, for: onMachine.id.rawValue).chrome.machineBadge == nil,
                "a hibernated machine tab shows the This Mac chip")
        let local = Self.placeholder(.appPage(BrowserAppPageState(url: HistoryPageAddress.url)))
        rig.keys.append(local.id.rawValue)
        #expect(rig.services.cache.install(local, for: local.id.rawValue).chrome.machineBadge != nil)
    }

    // MARK: Rig

    /// A tab whose record is `record`, opened unconfirmed and connected with its Connect button, as
    /// a person does; the tab streams.
    private static func connectedDesktop(_ rig: PageBrowserTabDiscardTests.Rig, record: RemoteViewTabRecord) throws
        -> (key: String, tab: RemoteViewPageTab, session: RemoteViewPageSession) {
        let (key, asking) = try rig.open(record.url)
        let connect = try #require((asking as? RemoteViewPageTab)?.debugConnect, "an unconfirmed desktop did not ask first")
        connect()
        let tab = try #require(rig.services.cache.browsers[key]?.tab as? RemoteViewPageTab)
        let session = try #require(tab.debugSession, "the confirmed desktop does not stream")
        tab.contentView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        tab.setContentVisible(true)
        return (key, tab, session)
    }

    /// Shows a streaming remote browser tab until a frame shows, then hides it; the test keeps only
    /// weak references to the tab and its pane.
    private static func showThenHide(in rig: HiddenPageHibernationTests.Rig, wakeRecord: URL) async throws -> Hidden {
        let stream = try RemoteStream()
        stream.tab.wakeRecord = { _ in wakeRecord }
        stream.tab.contentView.frame = NSRect(x: 0, y: 0, width: 160, height: 100)
        let key = stream.tab.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(stream.tab, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await until("a frame shows") { stream.damage(); return stream.presenter.presented > 0 }
        rig.services.cache.withdraw(key, by: rig.pane)
        #expect(!stream.tab.pane.isDecoding, "the hidden tab still decodes")
        return Hidden(key: key, tab: stream.tab, pump: stream.pump, pictureWidth: bitmapWidth(of: stream.tab.contentView))
    }

    /// A hidden tab, held weakly.
    private final class Hidden {
        let key: String
        weak var tab: RemoteBrowserTab?
        weak var pane: RemoteBrowserPane?
        let pump: Task<Void, Never>
        let pictureWidth: Int

        init(key: String, tab: RemoteBrowserTab, pump: Task<Void, Never>, pictureWidth: Int) {
            self.key = key
            self.tab = tab
            pane = tab.pane
            self.pump = pump
            self.pictureWidth = pictureWidth
        }
    }

    /// A remote browser tab on the mock desktop: a counting source, a recording presenter, a fake session.
    private struct RemoteStream {
        static let width = 320
        static let height = 200
        let tab: RemoteBrowserTab
        let source: CountingSource
        let presenter: RecordingPresenter
        let channel: FakeChannel
        let pump: Task<Void, Never>

        init(key: String? = nil) throws {
            let host = MockRemoteStreamSource(width: Self.width, height: Self.height)
            try #require(host.canEncode, "VideoToolbox has no H.264 encoder here")
            source = CountingSource(host: host)
            presenter = RecordingPresenter()
            channel = FakeChannel()
            let pane = RemoteBrowserPane(source: source, presenter: presenter)
            tab = RemoteBrowserTab(id: key.map(BrowserTabID.init(rawValue:)) ?? .random(), profile: .default,
                                   url: URL(string: "https://example.com/"), pane: pane, channel: channel)
            pump = source.run()
        }

        /// The host paints a frame.
        func damage() { source.host.damage() }

        func close() {
            pump.cancel()
            tab.close()
        }
    }

    /// Passes the host's access units to the current subscriber (the pane's pipeline) and counts
    /// every unit the host sent, subscribed or not.
    nonisolated final class CountingSource: RemoteViewStreamSource, Sendable {
        private struct State {
            var sent = 0
            var subscriber: AsyncStream<RemoteAccessUnit>.Continuation?
        }

        let host: MockRemoteStreamSource
        private let state = Mutex(State())

        init(host: MockRemoteStreamSource) {
            self.host = host
        }

        /// Forwards the host's units until cancelled.
        func run() -> Task<Void, Never> {
            let units = host.accessUnits()
            return Task.detached { [self] in
                for await unit in units {
                    let subscriber = state.withLock { state in
                        state.sent += 1
                        return state.subscriber
                    }
                    subscriber?.yield(unit)
                }
            }
        }

        var sent: Int { state.withLock { $0.sent } }

        func accessUnits() -> AsyncStream<RemoteAccessUnit> {
            let (stream, continuation) = AsyncStream.makeStream(of: RemoteAccessUnit.self, bufferingPolicy: .bufferingNewest(8))
            let previous = state.withLock { state in
                defer { state.subscriber = continuation }
                return state.subscriber
            }
            previous?.finish()
            return stream
        }

        func statusUpdates() -> AsyncStream<RemoteViewStatus> { host.statusUpdates() }
        func cursorUpdates() -> AsyncStream<RemoteCursorState> { host.cursorUpdates() }
        func requestKeyframe() { host.requestKeyframe() }
    }

    /// Decoded pictures that come only when the test hands one over, and that a stop does not
    /// interrupt: a decode in flight finishes and answers after the pane stopped.
    nonisolated final class HeldFrameSource: RemoteViewFrameSource, Sendable {
        private struct State {
            var waiting: CheckedContinuation<RemoteDecodedFrame?, Never>?
            var asked = 0
        }

        private let state = Mutex(State())

        func decodedFrames() -> AsyncStream<RemoteDecodedFrame> {
            // An unfolding stream returns what a running `produce` answers, even after a cancel.
            AsyncStream(unfolding: { [self] in await next() })
        }

        private func next() async -> RemoteDecodedFrame? {
            await withCheckedContinuation { (decoding: CheckedContinuation<RemoteDecodedFrame?, Never>) in
                state.withLock { state in
                    state.waiting = decoding
                    state.asked += 1
                }
            }
        }

        /// Decodes asked for so far.
        var asked: Int { state.withLock { $0.asked } }

        /// The decode in flight finishes with `frame`.
        func hand(_ frame: RemoteDecodedFrame) {
            let waiting = state.withLock { state in
                defer { state.waiting = nil }
                return state.waiting
            }
            waiting?.resume(returning: frame)
        }

        func accessUnits() -> AsyncStream<RemoteAccessUnit> { AsyncStream { $0.finish() } }
        func statusUpdates() -> AsyncStream<RemoteViewStatus> {
            AsyncStream { $0.yield(RemoteViewStatus(path: .direct, rttMs: 4, state: .streaming)) }
        }
        func cursorUpdates() -> AsyncStream<RemoteCursorState> { AsyncStream { _ in } }
        func requestKeyframe() {}
    }

    /// The layer-contents presenter, counting what the pipeline hands it.
    final class RecordingPresenter: RemoteFramePresenter {
        private nonisolated let shown: LayerContentsPresenter
        private nonisolated let count = Mutex(0)

        init() {
            shown = LayerContentsPresenter(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        }

        var kind: RemotePresenterKind { shown.kind }
        var layer: CALayer { shown.layer }
        var onFrameSize: ((CGSize) -> Void)? {
            get { shown.onFrameSize }
            set { shown.onFrameSize = newValue }
        }
        var onFrameShown: (() -> Void)? {
            get { shown.onFrameShown }
            set { shown.onFrameShown = newValue }
        }

        nonisolated func present(_ frame: RemoteDecodedFrame) {
            count.withLock { $0 += 1 }
            shown.present(frame)
        }

        func setBackingScale(_ scale: CGFloat) { shown.setBackingScale(scale) }
        nonisolated var discardedFrames: Int { shown.discardedFrames }
        var shownFrame: RemoteDecodedFrame? { shown.shownFrame }
        /// Frames handed to the presenter.
        nonisolated var presented: Int { count.withLock { $0 } }
    }

    /// The rb/1 session, faked: it records what the tab tells the host.
    final class FakeChannel: RemoteBrowserPageChannel {
        private(set) var visible: [Bool] = []
        func sendKey(_ event: NSEvent) -> UInt32 { 0 }
        func sendPointer(_ event: NSEvent, at point: CGPoint) {}
        func sendPointerFrame(_ input: PointerCoalescedInput, clickCount: Int, at point: CGPoint) {}
        func history(_ op: RemoteBrowserHistoryOp) {}
        func setVisible(_ visible: Bool) { self.visible.append(visible) }
        func load(_ url: URL) {}
        func close() {}
    }

    private static func machinePage() -> MachineBrowserPageTab {
        MachineBrowserPageTab(id: .random(), engine: .webkit, profile: .default,
                              record: MachineBrowserRecord(machine: "m1", initialURL: URL(string: "https://example.com/")),
                              state: { .notConnected("m1") }, openLocally: { _ in })
    }

    private static func placeholder(_ state: BrowserRestoreState) -> HibernatedBrowserTab {
        HibernatedBrowserTab(id: .random(), engine: .cef, profile: .default, state: BrowserTabState(url: URL(string: "https://example.com/")),
                             favicon: nil, restoreState: state, snapshot: { nil })
    }

    /// A decoded frame backed by an IOSurface, as VideoToolbox gives one.
    private static func decodedFrame(_ number: UInt32) -> RemoteDecodedFrame? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, 64, 40, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        return RemoteDecodedFrame(pixelBuffer: buffer, frame: number, tCaptureMicros: 0, decodedAtNanos: 0)
    }

    private static func picture() -> CGImage? {
        let context = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        return context?.makeImage()
    }

    /// The width in pixels of `view` drawn into a bitmap (`cacheDisplay`).
    private static func bitmapWidth(of view: NSView) -> Int {
        view.bitmapImageRepForCachingDisplay(in: view.bounds)?.pixelsWide ?? -1
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func until(_ what: @autoclosure () -> String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(await condition(), "\(what()) never happened")
    }
}

private extension RemoteBrowserTab {
    /// Gives the tab a record (a host it does not own) and returns it.
    @discardableResult
    func makeWakeRecord() -> URL {
        let address = URL(string: "cmux://remote-browser?address=127.0.0.1:9") ?? URL(fileURLWithPath: "/")
        wakeRecord = { _ in address }
        return address
    }
}
#endif
