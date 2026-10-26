import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextRemoteBrowser
@testable import CmuxNextRemoteView
@testable import CmuxNextRemoteViewSessions
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

#if DEBUG
/// Remote view tabs under Memory Saver (p07-memory-085, feature `memoryDiscardRemoteTabs`). A
/// hidden remote browser tab went on decoding its stream (only the host was told it hid), and no
/// remote tab could be discarded: none was a `BrowserHibernationSource`, so each kept its stream,
/// decoder and presenter for as long as it lived. Now hiding pauses the decode in the same turn,
/// a tab hidden past the timeout (or at critical pressure) becomes a hibernated tab holding its
/// last frame, and showing it builds the tab again from its address, behind that frame until the
/// new stream's first one. The host is the VideoToolbox mock desktop behind a counting source;
/// the remote browser session is a fake channel.
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

    @Test func hidingARemoteDesktopPaneStopsItsFrames() async throws {
        let host = MockRemoteStreamSource(width: 320, height: 200)
        try #require(host.canEncode)
        let source = CountingSource(host: host)
        let pump = source.run()
        defer { pump.cancel() }
        let pane = RemoteDesktopPane(hostName: RemoteViewPageSession.mockHost, source: source, inputSink: nil, presenter: .layerContents)
        pane.start()
        try await Self.until("a frame shows") { host.damage(); return pane.lastFrame != nil }

        pane.stop()
        // A frame presented before the stop shows on a later main-actor turn; these frames give it those turns.
        var sent = source.sent
        try await Self.until("the host sent three more frames") { host.damage(); return source.sent >= sent + 3 }
        let last = pane.lastFrame?.frame
        sent = source.sent
        try await Self.until("the host sent three more frames") { host.damage(); return source.sent >= sent + 3 }
        #expect(pane.lastFrame?.frame == last, "a stopped pane presented frames")
        #expect(pane.lastFrame != nil, "the stopped pane dropped its last frame")
    }

    // MARK: Discard

    @Test func aHiddenRemoteBrowserTabIsDiscardedToItsLastFrameAndItsDecoderGoes() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let address = try #require(URL(string: "cmux://remote-browser?address=127.0.0.1:9"))
        let hidden = try await Self.showThenHide(in: rig, wakeAddress: address)
        defer { hidden.pump.cancel() }
        // The rig is at critical pressure: a page hidden 10 s goes, with no page probe to answer.
        try await rig.until("the tab was discarded") { rig.isHibernated(hidden.key) || rig.exemption(hidden.key) != nil }
        try #require(rig.isHibernated(hidden.key), "kept: \(String(describing: rig.exemption(hidden.key)))")

        try await rig.until("the stream's tab, pane and decoder went") { hidden.tab == nil && hidden.pane == nil }
        let asleep = try #require(rig.services.cache.browsers[hidden.key]?.tab as? HibernatedBrowserTab)
        #expect(asleep.restoreState == .page(address))
        let picture = try #require(asleep.snapshotImage, "the hibernated tab has no last frame")
        #expect(picture.width == RemoteStream.width)
    }

    @Test func showingTheDiscardedTabConnectsAgainBehindItsLastFrame() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        // The cap never runs out here: only the new stream's first frame removes the picture.
        rig.hibernation.standInClock = ManualClock()
        let address = try #require(URL(string: "cmux://remote-browser?address=127.0.0.1:9"))
        let hidden = try await Self.showThenHide(in: rig, wakeAddress: address)
        defer { hidden.pump.cancel() }
        try #require(rig.hibernation.hibernateNow(hidden.key) == nil)
        try await rig.until("the tab was discarded") { rig.isHibernated(hidden.key) }

        let next = try RemoteStream(key: hidden.key)
        defer { next.close() }
        var asked: URL?
        rig.hibernation.buildPage = { _, url in
            asked = url
            return next.tab
        }
        var atSwap: (covered: Bool, presented: Int)?
        let previous = rig.services.cache.onBrowserReady
        rig.services.cache.onBrowserReady = { ready in
            previous?(ready)
            guard ready == hidden.key, atSwap == nil else { return }
            atSwap = (next.tab.showsWakeCover, next.presenter.presented)
        }
        rig.services.cache.present(hidden.key, by: rig.pane, presence: .visible)
        try await rig.until("the tab was built again") { atSwap != nil }
        #expect(asked == address)
        #expect(atSwap?.covered == true, "the new tab did not start under the last frame")
        #expect(atSwap?.presented == 0)

        try await Self.until("the new stream shows a frame") { next.damage(); return next.presenter.presented > 0 }
        try await Self.until("its first frame took the last frame away") { !next.tab.showsWakeCover }
    }

    @Test func aRemoteDesktopTabIsDiscardedToItsRecord() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let record = try #require(RemoteViewTabRecord(host: RemoteViewPageSession.mockHost))
        var tab: RemoteViewPageTab? = RemoteViewPageTab(id: .random(), engine: .webkit, profile: .default, url: record.url,
                                                        decision: .confirm(record), closeTab: {}, connect: { _ in })
        weak var gone = tab
        let key = try #require(tab).id.rawValue
        #expect(tab?.supportsHibernation == false, "a tab the App did not mark discardable can be discarded")
        tab?.wakeAddress = record.url
        rig.keys.append(key)
        rig.services.cache.install(try #require(tab), for: key)
        tab = nil
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        rig.services.cache.withdraw(key, by: rig.pane)

        try #require(rig.hibernation.hibernateNow(key) == nil)
        try await rig.until("the tab was discarded") { rig.isHibernated(key) }
        let asleep = try #require(rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)
        #expect(asleep.restoreState == .page(record.url))
        try await rig.until("the old tab went") { gone == nil }
    }

    // MARK: What may go

    /// A new connection starts a new remote runtime: a page with back or forward history would
    /// lose it, so it stays; a tab the App did not mark (the feature off) never goes.
    @Test func aRemotePageWithHistoryIsNotDiscarded() throws {
        let stream = try RemoteStream()
        defer { stream.close() }
        #expect(!stream.tab.supportsHibernation, "a tab with no wake address can be discarded")
        let address = try #require(URL(string: "cmux://remote-browser?address=127.0.0.1:9"))
        stream.tab.makeWakeAddress = { _ in address }
        #expect(stream.tab.supportsHibernation)
        #expect(stream.tab.hibernationState() == .page(address))
        // Duplicate and Reopen Closed Tab open the address; it is no engine history.
        #expect(BrowserRestoreState.history(of: stream.tab) == nil)

        stream.tab.applyPage(url: URL(string: "https://example.com/next"), title: "Next", loading: false, canGoBack: true, canGoForward: false)
        #expect(!stream.tab.supportsHibernation, "a remote page with back history can be discarded")
        #expect(stream.tab.hibernationState() == nil)
    }

    // MARK: Rig

    /// Shows a streaming remote browser tab until a frame shows, then hides it; the test keeps only
    /// weak references to the tab and its pane.
    private static func showThenHide(in rig: HiddenPageHibernationTests.Rig, wakeAddress: URL) async throws -> Hidden {
        let stream = try RemoteStream()
        stream.tab.makeWakeAddress = { _ in wakeAddress }
        let key = stream.tab.id.rawValue
        rig.keys.append(key)
        rig.services.cache.install(stream.tab, for: key)
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await until("a frame shows") { stream.damage(); return stream.presenter.presented > 0 }
        rig.services.cache.withdraw(key, by: rig.pane)
        #expect(!stream.tab.pane.isDecoding, "the hidden tab still decodes")
        return Hidden(key: key, tab: stream.tab, pump: stream.pump)
    }

    /// A hidden tab, held weakly.
    private final class Hidden {
        let key: String
        weak var tab: RemoteBrowserTab?
        weak var pane: RemoteBrowserPane?
        let pump: Task<Void, Never>

        init(key: String, tab: RemoteBrowserTab, pump: Task<Void, Never>) {
            self.key = key
            self.tab = tab
            pane = tab.pane
            self.pump = pump
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

    /// The layer-contents presenter, counting what the pipeline hands it.
    final class RecordingPresenter: RemoteFramePresenter {
        private nonisolated let shown: LayerContentsPresenter
        private nonisolated let count = Mutex(0)

        init() {
            shown = LayerContentsPresenter()
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
        func history(_ op: RemoteBrowserHistoryOp) {}
        func setVisible(_ visible: Bool) { self.visible.append(visible) }
        func load(_ url: URL) {}
        func close() {}
    }

    private static func until(_ what: @autoclosure () -> String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(await condition(), "\(what()) never happened")
    }
}
#endif
