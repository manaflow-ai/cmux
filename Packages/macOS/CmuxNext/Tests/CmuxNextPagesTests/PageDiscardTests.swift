import AppKit
#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
#else
import CmuxNextCompat
#endif
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import ImageIO
import CmuxNextSettings
import Testing
import WebKit

/// A page keeps its picture and its state from the turn it hides, and a discard makes no call into the
/// page: a frozen page cannot answer, so the old design's discard-time save call kept a
/// page frozen for 300 s from ever being discarded.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageDiscardTests {
    /// A page target that logs each step the lifecycle takes on it.
    private final class Steps {
        var lines: [String] = []
    }

    private struct Target: PageLifecycleTarget {
        let name: String
        let page: Steps
        var object: AnyObject? { page }
        var lifecycleGroup: String? { "privileged" }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> { [] }
        func reportsReasonChanges(to lifecycle: PageLifecycle) {}
        func keepHideSnapshot() { page.lines.append("keep \(name)") }
        func dropHideSnapshot() { page.lines.append("drop \(name)") }
        func freeze() -> Bool {
            page.lines.append("freeze \(name)")
            return true
        }
        func thaw() { page.lines.append("thaw \(name)") }
        func discard() -> Bool {
            page.lines.append("discard \(name)")
            return true
        }
    }

    /// An encoder that records what it is given and answers at once: a frame with ``answer``, a surface
    /// copy with its own PNG.
    @MainActor private final class RecordingEncoder {
        var images: [CGImage] = []
        var unpacked: [PageSurfaceCopy] = []
        var answer: PageEncodedSnapshot?

        var encoder: PageSnapshotEncoder {
            PageSnapshotEncoder(start: { [self] image, done in
                images.append(image)
                done(answer)
            }, unpack: { [self] copy, done in
                unpacked.append(copy)
                done(copy.encoded())
            })
        }

        /// An encoder whose answer waits for ``finish(_:)`` (an encode still on the lane).
        @MainActor final class Pending {
            private var done: PageSnapshotEncoder.Done?

            var encoder: PageSnapshotEncoder {
                PageSnapshotEncoder { [self] _, done in self.done = done }
            }

            func finish(_ snapshot: PageEncodedSnapshot?) {
                done?(snapshot)
                done = nil
            }
        }
    }

    private let rig = LifecycleDeadlineRig()
    private let lifecycle: PageLifecycle
    private let descriptor = PageDescriptor(id: "test.page-discard", resource: "page-discard", processGroup: .solo, namespaces: [])
    private static let picture = PageEncodedSnapshot(data: Data([0x89, 0x50, 0x4E, 0x47]), pixelSize: CGSize(width: 200, height: 160))
    /// ``picture`` as Chromium's surface copy answers it, in base64.
    private static let surfaceCopy = PageSurfaceCopy(base64: picture.data.base64EncodedString(), pixelSize: picture.pixelSize)

    init() {
        lifecycle = PageLifecycle(conditions: .discarding(), deadlines: rig.scheduler)
    }

    /// Fires the armed pass until `key` is discarded; false when it never is.
    private func runPasses(until key: String, is state: PageLifecycle.State) -> Bool {
        for _ in 0..<12 where lifecycle.state(of: key) != state {
            guard lifecycle.nextPassAt != nil else { return false }
            rig.fire()
        }
        return lifecycle.state(of: key) == state
    }

    private func image(width: Int = 4, height: Int = 3) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func chromiumView(root: URL) async throws -> (PageWebView, FakeChromiumPage) {
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting, deadlines: .testing()))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        view.frame = NSRect(x: 0, y: 0, width: 100, height: 80)
        view.loaded = true // its document finished: no loading keep reason
        return (view, try #require(hosting.made.first))
    }

    private func pageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-discard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        return root
    }

    // MARK: The lifecycle's order

    @Test func theHideKeepsThePictureBeforeAnyFreeze() {
        let steps = Steps()
        lifecycle.hide("h", page: Target(name: "history", page: steps))
        #expect(steps.lines == ["keep history"], "the picture is taken in the hide's own turn")
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(name: "cloud", page: Steps()))
        rig.fire()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(steps.lines == ["keep history", "freeze history"])
    }

    @Test func aPageFrozen300SecondsIsDiscardedInThePassThatPicksIt() {
        let steps = Steps()
        lifecycle.hide("h", page: Target(name: "history", page: steps))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(name: "cloud", page: Steps()))
        rig.fire()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(runPasses(until: "h", is: .discarded), "a frozen page was never discarded")
        #expect(rig.now > .seconds(299) && rig.now < .seconds(301), "discarded at \(rig.now), not at 300 s")
        #expect(steps.lines == ["keep history", "freeze history", "discard history"])
    }

    @Test func aShowDropsThePictureOfAHiddenPageAndKeepsADiscardedOnes() {
        let steps = Steps()
        let target = Target(name: "settings", page: steps)
        lifecycle.hide("a", page: target)
        lifecycle.show("a", page: target)
        #expect(steps.lines == ["keep settings", "drop settings"])
        steps.lines = []
        lifecycle.hide("a", page: target)
        #expect(runPasses(until: "a", is: .discarded))
        lifecycle.show("a", page: target)
        #expect(steps.lines == ["keep settings", "discard settings", "thaw settings"], "a discarded page shows its picture while it loads")
    }

    @Test func aSecondHideOfAHiddenPageTakesNoNewPicture() {
        let steps = Steps()
        let target = Target(name: "settings", page: steps)
        lifecycle.hide("a", page: target)
        lifecycle.hide("a", page: target)
        #expect(steps.lines == ["keep settings"])
    }

    // MARK: A real page

    /// A Chromium page copies its surface when it hides (no DevTools), its base64 goes to the encoder's
    /// unpack (off the main thread in the app), and the discard 300 s later makes no call into the page and
    /// encodes nothing more: Chromium's copy comes encoded.
    @Test func aChromiumPageKeepsItsSurfaceCopyAtTheHideAndIsDiscardedWithNoPageCall() async throws {
        let root = try pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumView(root: root)
        let (other, _) = try await chromiumView(root: root)
        page.surfaceCopy = Self.surfaceCopy
        let encoder = RecordingEncoder()
        let calls = page.calls.count, evaluations = page.evaluations.count
        lifecycle.hide("a", page: PageWebViewLifecycle(view, encoder: encoder.encoder))
        #expect(page.surfaceCopies == [CGSize(width: 200, height: 160)], "one copy at the view's 2x size, in the hide's turn")
        #expect(encoder.unpacked == [Self.surfaceCopy], "the copy's base64 was not unpacked by the encoder")
        #expect(view.hideState.encoded == Self.picture)
        rig.advance(to: .seconds(5))
        lifecycle.hide("b", page: PageWebViewLifecycle(other, encoder: encoder.encoder))
        rig.fire()
        #expect(lifecycle.state(of: "a") == .frozen)
        #expect(runPasses(until: "a", is: .discarded), "a frozen page was never discarded")
        #expect(page.calls.count == calls, "a DevTools call: \(page.calls.dropFirst(calls).map { $0.method })")
        #expect(page.evaluations.count == evaluations, "a call into the page")
        #expect(page.surfaceCopies.count == 1, "the discard took a picture of its own")
        #expect(encoder.images.isEmpty, "a Chromium copy is encoded already")
        #expect(encoder.unpacked.count == 1, "the discard unpacked again")
        #expect(view.hideState.encoded == Self.picture)
        view.close()
        other.close()
    }

    /// A WebKit page pictures its last frame at the hide, in its window, before any freeze; the frame
    /// is encoded as it comes and only the encoded copy stays. The discard 300 s later makes no call
    /// and encodes nothing more.
    @Test func aWebKitPageEncodesItsHideFrameAsItComesAndIsDiscardedWithNoPageCall() async throws {
        let root = try pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil, deadlines: .testing()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        let painted: Bool? = await PageTestWait.value("paint") { done in view.whenPainted { done(true) } }
        try #require(painted == true)
        view.loaded = true // its document finished: no loading keep reason
        let encoder = RecordingEncoder()
        encoder.answer = Self.picture
        let target = PageWebViewLifecycle(view, encoder: encoder.encoder)

        lifecycle.hide("a", page: target)
        #expect(view.hideState.picture == .capturing, "the hide asked WebKit for no picture")
        let frame = await view.hideFrame()
        #expect(frame != nil, "WebKit gave no frame of the page as it hid")
        #expect(encoder.images.count == 1, "the frame was not encoded as it came")
        #expect(view.hideState.encoded == Self.picture)
        #expect(lifecycle.state(of: "a") == .hidden, "the picture came after a freeze")
        view.isHidden = true // the tab's conceal hides the view after the lifecycle's hide

        rig.advance(to: .seconds(5))
        lifecycle.hide("b", page: Target(name: "other", page: Steps()))
        rig.fire()
        #expect(lifecycle.state(of: "a") == .frozen)
        #expect(runPasses(until: "a", is: .discarded), "a frozen page was never discarded")
        #expect(encoder.images.count == 1, "the discard encoded again")
        #expect(view.hideState.encoded == Self.picture)
        view.close()
    }

    /// A hidden page a discard-blocking reason keeps (pinned) is never discarded, and holds only its
    /// encoded picture: no decoded frame stays for as long as it is hidden.
    @Test func aPageKeptFromDiscardHoldsOnlyItsEncodedPicture() throws {
        let state = PageHideState()
        let encoder = RecordingEncoder()
        encoder.answer = Self.picture
        lifecycle.hide("h", page: Target(name: "history", page: Steps()))
        lifecycle.setKeepReasons([.pinned], for: "h")
        state.captured(state.beginCapture(), frame: try image(), encoder: encoder.encoder)
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(name: "cloud", page: Steps()))
        rig.fire()
        #expect(!runPasses(until: "h", is: .discarded), "a pinned page was discarded")
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(encoder.images.count == 1)
        #expect(state.picture == .encoded(Self.picture), "the hidden page keeps \(state.picture), not its encoded picture")
    }

    @Test func aPageKeepsTheStateItPostsWhenItHides() throws {
        let root = try pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil, deadlines: .testing()))
        let post = try #require(view.chromiumMessageHandlers[PageWebView.pageStateHandler], "no state handler installed")
        post(#"{"scroll":120}"#)
        #expect(view.hideState.savedState == #"{"scroll":120}"#)
        // What pageLifecycle.ts `writePageState` posts for a state over the limit, or for none.
        post("null")
        #expect(view.hideState.savedState == nil, "the page cleared its state and the text null was kept")
        post(#"{"scroll":0}"#)
        post(String(repeating: "x", count: PageHideState.maxStateBytes + 1))
        #expect(view.hideState.savedState == nil, "an oversized state replaced nothing and was kept")
        post(#"{"scroll":0}"#)
        post(["not": "text"])
        #expect(view.hideState.savedState == nil)
        view.close()
    }

    // MARK: The picture's state

    /// WebKit's frame is encoded in the turn it comes; the state never holds it decoded.
    @Test func aFrameIsEncodedAsItComes() throws {
        let state = PageHideState()
        let encoder = RecordingEncoder()
        encoder.answer = Self.picture
        state.captured(state.beginCapture(), frame: try image(), encoder: encoder.encoder)
        #expect(encoder.images.count == 1)
        #expect(state.encoded == Self.picture)
    }

    /// The frame waiters (a page tab's discard cover) get the frame as it comes, and nil when the
    /// capture is replaced; with no capture on its way there is nothing to wait for.
    @Test func theHideFrameGoesToItsWaitersOnce() throws {
        let state = PageHideState()
        var frames: [CGImage?] = []
        #expect(!state.whenFrameArrives { frames.append($0) }, "a wait with no capture on its way")
        let capture = state.beginCapture()
        #expect(state.whenFrameArrives { frames.append($0) })
        let frame = try image()
        state.captured(capture, frame: frame, encoder: PageSnapshotEncoder { _, done in done(nil) })
        #expect(frames.count == 1)
        #expect(frames.first.flatMap { $0 } === frame)
        _ = state.beginCapture()
        #expect(state.whenFrameArrives { frames.append($0) })
        state.drop()
        #expect(frames.count == 2)
        #expect(frames.last.flatMap { $0 } == nil)
    }

    @Test func anEncodeThatFinishesAfterTheShowIsDropped() throws {
        let pending = RecordingEncoder.Pending()
        let state = PageHideState()
        state.captured(state.beginCapture(), frame: try image(), encoder: pending.encoder)
        #expect(state.picture == .encoding)
        state.drop()
        pending.finish(Self.picture)
        #expect(state.encoded == nil, "an encode of a page that showed again was kept")
    }

    @Test func aPictureThatComesAfterTheShowIsDropped() throws {
        let state = PageHideState()
        let encoder = RecordingEncoder()
        let capture = state.beginCapture()
        state.drop()
        state.captured(capture, frame: try image(), encoder: encoder.encoder)
        #expect(encoder.images.isEmpty, "a frame of a page that showed again was encoded")
        #expect(state.picture == .empty)
        let newer = state.beginCapture()
        state.captured(capture, encoded: Self.picture)
        #expect(state.encoded == nil, "an older capture's answer replaced the newer one")
        state.captured(newer, encoded: Self.picture)
        #expect(state.encoded == Self.picture)
    }

    /// The app's encoder unpacks a surface copy's base64 (megabytes of text for a full window) on the `.cpu`
    /// lane, never in the main actor's turn: the main thread records no cpu-intensive site.
    @Test func theAppEncoderUnpacksASurfaceCopyOnTheCPULane() async throws {
        let (ran, report) = AsyncStream<BlockingLane>.makeStream()
        let work = BackgroundWork(cpuWidth: 1, label: "test.page-unpack", onRan: { lane, _, _, _ in report.yield(lane) })
        let encoder = PageSnapshotEncoder(work: work, mainWork: rig.work)
        let png = Data(repeating: 0xAB, count: 256 * 1024)
        let copy = PageSurfaceCopy(base64: png.base64EncodedString(), pixelSize: CGSize(width: 512, height: 512))
        try #require(copy.base64.utf8.count > BlockingKind.cpuIntensiveJSONBytes)
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) { encoder.unpack(copy) { _ in } }
        #else
        encoder.unpack(copy) { _ in }
        #endif
        var lanes = ran.makeAsyncIterator()
        #expect(await lanes.next() == .cpu, "the unpack did not run on the .cpu lane")
        #if DEBUG || CMUX_BLOCKING_CHECKS
        await table.flush()
        #expect(table.sites.filter { $0.kind == .cpuIntensive }.isEmpty, "the unpack ran on the main thread: \(table.sites)")
        #endif
        await work.shutdown()
    }

    /// The app's encoder runs the encode on the `.cpu` lane at QoS utility, never on the main thread,
    /// makes a PNG of the frame's size, and records no wrong-lane site: the in-memory encode goes through
    /// the CPU seam (`blockingImageEncode`), not a file seam.
    @Test func theAppEncoderEncodesOnAUtilityLane() async throws {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let sink = PageDiscardViolations()
        BlockingDetector(table: table).install(sink: sink)
        #endif
        let (seen, report) = AsyncStream<(onMain: Bool, qos: UInt32, snapshot: PageEncodedSnapshot?)>.makeStream()
        let encoder = PageSnapshotEncoder(work: BackgroundWork(cpuWidth: 1, label: "test.page-snapshot"), mainWork: rig.work) { image in
            // A lane thread does not inherit the test's task-locals, so the encode binds the test's table.
            #if DEBUG || CMUX_BLOCKING_CHECKS
            let snapshot = BlockingViolationTable.$scoped.withValue(table) { PageSnapshotEncoder.png(image) }
            #else
            let snapshot = PageSnapshotEncoder.png(image)
            #endif
            report.yield((Thread.isMainThread, qos_class_self().rawValue, snapshot))
            return snapshot
        }
        // Above the CPU seam's image gate (256 KiB of pixels), as a real page frame is.
        encoder.encode(try image(width: 600, height: 500)) { _ in }
        var iterator = seen.makeAsyncIterator()
        let run = try #require(await iterator.next())
        #expect(!run.onMain)
        #expect(run.qos == QOS_CLASS_UTILITY.rawValue)
        let snapshot = try #require(run.snapshot)
        #expect(snapshot.pixelSize == CGSize(width: 600, height: 500))
        let decoded = try #require(CGImageSourceCreateWithData(snapshot.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 600 && decoded.height == 500)
        #expect(decoded.alphaInfo != .none && decoded.alphaInfo != .noneSkipLast && decoded.alphaInfo != .noneSkipFirst, "the PNG lost its alpha")
        #if DEBUG || CMUX_BLOCKING_CHECKS
        await table.flush()
        let sites = BlockingDetector(table: table).sites
        #expect(sites.isEmpty, "the encode recorded \(sites.map { "\($0.kind) at \($0.location)" })")
        #expect(sink.violations.isEmpty)
        #endif
    }
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// The violations the detector hands its sink (``PageDiscardTests/theAppEncoderEncodesOnAUtilityLane()``).
private nonisolated final class PageDiscardViolations: BlockingViolationSink, Sendable {
    private let seen = Mutex<[BlockingViolation]>([])
    var violations: [BlockingViolation] { seen.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        seen.withLock { $0.append(violation) }
    }
}
#endif

/// A page's discard and restore (plans/cmux-next/chrome-parity/p13-webui.md 3.C, task 030): the
/// discard makes no call into the page and ends its engine page and subscriptions in one turn, the
/// shell keeps route, snapshot and state, and the show draws the snapshot, makes the engine page
/// again from the same host and hands the new document its state before its first paint.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageDiscardRestoreTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.discard-page", resource: "discard-page", processGroup: .viewer,
                                            namespaces: ["test.discard."])
    private let provider = LiveSubscriptions()
    /// The hide's encoded picture as the tests keep it (its bytes are never decoded: ``decoder`` answers).
    private static let encoded = PageEncodedSnapshot(data: Data([0x89, 0x50, 0x4E, 0x47]), pixelSize: CGSize(width: 4, height: 2))
    /// Encodes nothing and decodes the kept picture at once to ``picture``.
    private let decoder: PageSnapshotEncoder
    private let picture: CGImage

    init() throws {
        let picture = try Self.image()
        self.picture = picture
        decoder = PageSnapshotEncoder(start: { _, done in done(nil) }, decode: { _, done in done(picture) })
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-discard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeView(_ hosting: FakeChromiumHosting?) throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root,
                                            routes: [PageRoute(prefix: "test.discard.", provider: provider)],
                                            route: "#/a", chromium: hosting, deadlines: .testing()))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        return view
    }

    private func subscribe(_ view: PageWebView) async {
        let reply = await view.router.handle(["t": "sub", "id": 1, "stream": "test.discard.changed"])
        #expect(reply["t"]?.stringValue == "ok")
    }

    /// The acceptance: a discarded shell holds no engine page and no subscription, and the discard
    /// made no call into the page (no DevTools call, no script), all before it returned.
    @Test func aDiscardEndsTheEnginePageAndSubscriptionsWithNoCallIntoThePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        await subscribe(view)
        #expect(view.router.subscriptionCount == 1)
        #expect(provider.live == 1)
        let calls = page.calls.count, evaluations = page.evaluations.count

        #expect(view.discardPage(decoder: decoder))

        #expect(view.isDiscarded)
        #expect(view.chromiumPage == nil)
        #expect(page.closed)
        #expect(page.contentView.superview == nil)
        #expect(view.router.subscriptionCount == 0)
        #expect(provider.live == 0)
        #expect(page.calls.count == calls, "the discard called into the page")
        #expect(page.evaluations.count == evaluations, "the discard ran a script in the page")
        #expect(!view.loadState.isLoading, "a discarded page reads as loading and blocks its lifecycle")
        // The old document may still post (a message WebKit queued before the discard, its
        // `pagehide`): the router stays closed until the restore, so no provider sees it.
        let late = await view.router.handle(["t": "sub", "id": 2, "stream": "test.discard.changed"])
        #expect(late["t"]?.stringValue == "err", "a discarded shell took a subscription")
        #expect(provider.live == 0)
        #expect(view.router.subscriptionCount == 0)
        // The shell keeps its route; nothing loads until it shows.
        view.open(route: "/b")
        #expect(view.route == "#/b")
        #expect(hosting.made.count == 1)
        view.reload()
        #expect(hosting.made.count == 1)
    }

    @Test func aShownPageIsNotDiscarded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try makeView(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        defer {
            view.close()
            view.removeFromSuperview()
        }
        #expect(!view.discardPage(decoder: decoder))
        #expect(!view.isDiscarded)
        #expect(view.webView.navigationDelegate === view)
    }

    /// A page parked in the preload slot refuses (the slot owns its life); a parked page an open claimed is a page
    /// like any other: it discards, and its show brings it back.
    @Test func aClaimedPooledHostDiscardsAndTheParkedSpareRefuses() throws {
        let configuration = WKWebViewConfiguration()
        let view = PageWebView(descriptor: descriptor, configuration: configuration,
                               inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: "#/a",
                               options: .standard, surface: nil, dynamicResources: nil, pooled: true, load: false,
                               chromium: nil, deadlines: .testing())
        defer { view.close() }
        #expect(view.isPooled)
        let parking = PagePreloadParkingView(frame: .zero)
        parking.addSubview(view)
        #expect(view.isParkedSpare)
        #expect(!view.discardPage(decoder: decoder))
        #expect(!view.isDiscarded)
        #expect(PageWebViewLifecycle(view, encoder: decoder).lifecycleKeepReasons.contains(.preload),
                "the lifecycle plans a discard the parked spare refuses")

        // Claimed: out of the parking, into a page's place.
        view.removeFromSuperview()
        #expect(!view.isParkedSpare)
        #expect(!PageWebViewLifecycle(view, encoder: decoder).lifecycleKeepReasons.contains(.preload))
        #expect(view.discardPage(decoder: decoder))
        #expect(view.isDiscarded)
        view.restoreDiscardedPage()
        #expect(!view.isDiscarded)
    }

    /// Through the lifecycle: a page that refuses its discard (it is concealed but still shows in its
    /// window) keeps its state, so the lifecycle never reports a page discarded that holds its document.
    @Test func aRefusedDiscardLeavesTheLifecycleStateUnchanged() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = LifecycleDeadlineRig()
        let lifecycle = PageLifecycle(conditions: .discarding(), deadlines: rig.scheduler)
        let view = try makeView(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        defer {
            view.close()
            view.removeFromSuperview()
        }
        view.loaded = true
        let target = PageWebViewLifecycle(view, encoder: decoder)
        lifecycle.hide("tab", page: target)
        rig.advance(to: .seconds(900))
        lifecycle.runPass()
        #expect(!view.isDiscarded)
        #expect(lifecycle.state(of: "tab") != .discarded, "the lifecycle reports a refused discard as done")
        #expect(lifecycle.nextPassAt != nil, "nothing looks at the refused page again")

        // Hidden in AppKit too: the next pass discards it.
        view.isHidden = true
        lifecycle.runPass()
        #expect(view.isDiscarded)
        #expect(lifecycle.state(of: "tab") == .discarded)
    }

    /// 10 discard and restore cycles make one engine page per restore from the same host and close
    /// each before the next: one live engine page at the end, as at the start, loading the route the
    /// shell kept (the fake's count stands for `runtime.hosts`, which p13-webui-062 empties per close).
    @Test func tenDiscardAndRestoreCyclesLeaveOneLiveEnginePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        await view.chromiumStart?.value
        for cycle in 0..<10 {
            if cycle == 4 { view.open(route: "/b") }
            #expect(view.discardPage(decoder: decoder))
            #expect(hosting.made.filter { !$0.closed }.isEmpty)
            view.restoreDiscardedPage()
            #expect(!view.isDiscarded)
            await view.chromiumStart?.value
            #expect(hosting.made.filter { !$0.closed }.count == 1)
        }
        #expect(hosting.made.count == 11)
        let last = try #require(hosting.made.last)
        #expect(view.chromiumPage === last)
        #expect(last.loaded == [descriptor.url(route: "#/b")])
    }

    /// The show draws the hide-time snapshot in its own turn, in a layer with no implicit actions;
    /// the new document gets the saved state from a document-start script; both go at its first paint.
    @Test func theRestoreDrawsTheSnapshotAndHandsTheStateToTheNewDocumentUntilItPaints() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        await view.chromiumStart?.value
        let image = picture
        Self.keepHide(view, state: #"{"draft":"hello"}"#)
        #expect(view.discardPage(decoder: decoder))

        view.restoreDiscardedPage()

        #expect(view.showsDiscardSnapshot)
        #expect(view.drawsDiscardSnapshot)
        let restore = try #require(view.lastRestoreTimes)
        #expect(restore.covered == restore.started, "the snapshot went over the page after the show's turn")
        #expect(restore.painted == nil)
        let cover = try #require(view.discardShell.cover)
        #expect(cover.superlayer === view.layer)
        #expect(cover.frame == view.bounds)
        #expect((cover.contents as AnyObject?) === image)
        for key in ["contents", "bounds", "position", "hidden", "onOrderIn", "onOrderOut"] {
            #expect(cover.actions?[key] is NSNull, "the snapshot layer animates \(key)")
        }
        #expect(view.loadState.isLoading)
        let scripts = view.userContent.userScripts.map(\.source)
        let script = try #require(scripts.first { $0.contains(PageWebView.restoreGlobal) })
        #expect(script.contains(#""{\"draft\":\"hello\"}""#), "the saved state went in as anything but a string literal")
        #expect(script.contains("wasDiscarded: true"))
        #expect(script.contains(#"sessionStorage.setItem("cmux.page.state", text)"#))
        #expect(view.hideState.encoded == nil, "a shown page keeps the picture of its last hide")
        #expect(view.hideState.savedState == nil, "a shown page keeps the state of its last hide")

        await view.chromiumStart?.value
        let page = try #require(hosting.made.last)
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument"
            && ($0.params["source"] as? String)?.contains(PageWebView.restoreGlobal) == true },
                "the Chromium page got no restore script before its document")
        #expect(page.loaded == [descriptor.url(route: "#/a")])

        let painted: Bool? = await PageTestWait.value("paint") { done in
            view.whenPainted { done(true) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PagePaintProbe.handlerName, "body": 5])))
        }
        #expect(painted == true)
        #expect(!view.showsDiscardSnapshot)
        #expect(cover.superlayer == nil)
        #expect(!view.userContent.userScripts.contains { $0.source.contains(PageWebView.restoreGlobal) })
        #expect(view.discardShell.snapshot == nil)
        #expect(view.lastRestoreTimes?.painted == view.paintedUptime)
        #expect(view.lastRestoreTimes?.painted != nil)
    }

    /// A discarded page with a kept snapshot draws it as its next frame, before its show: the pane
    /// holds nothing for it (InternalPageView reads this). One with no snapshot waits for its paint.
    @Test func aDiscardedPageWithASnapshotHasAFrameBeforeItsShow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        await view.chromiumStart?.value
        #expect(view.discardPage(decoder: decoder))
        #expect(!view.drawsDiscardSnapshot, "no snapshot was kept: the page has no frame to show")
        view.restoreDiscardedPage()
        await view.chromiumStart?.value

        Self.keepHide(view, state: nil)
        #expect(view.discardPage(decoder: decoder))
        #expect(!view.hasPainted)
        #expect(view.drawsDiscardSnapshot)
    }

    /// A WebKit page leaves its document with no delegate, so nothing of it reaches the host, and
    /// comes back in the same view (its process group) with the delegate set again.
    @Test func aWebKitPageLeavesItsDocumentAndComesBackInTheSameView() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try makeView(nil)
        defer { view.close() }
        let webView = view.webView
        #expect(view.discardPage(decoder: decoder))
        #expect(webView.navigationDelegate == nil)
        #expect(webView.isHidden)
        view.restoreDiscardedPage()
        #expect(view.webView === webView)
        #expect(webView.navigationDelegate === view)
        #expect(!webView.isHidden)
        #expect(!view.showsDiscardSnapshot, "no snapshot was kept, so none is drawn")
    }

    /// The restore script hands its state to the first document only: a later document of the same
    /// Chromium page (a reload after a crash) finds the token in session storage.
    @Test func theRestoreScriptRunsOncePerRestore() {
        let script = PageWebView.restoreScript(state: nil, token: "t1")
        #expect(script.contains(#"sessionStorage.getItem("cmux.page.restore.t1")"#))
        #expect(script.contains(#"window.__cmuxPageRestore = {"#))
        #expect(script.contains("const text = null;"))
        #expect(script.contains(#"Object.defineProperty(document, "wasDiscarded""#))
        // Text the page saved is a string literal the page parses: it never runs as script.
        let hostile = PageWebView.restoreScript(state: #"1}); alert(1); ({"#, token: "t2")
        #expect(hostile.contains(#"const text = "1}); alert(1); ({";"#))
    }

    /// Through the lifecycle: a discard-blocking keep reason keeps a page past its discard time; once
    /// it goes, the next pass discards the page, and its show brings it back.
    @Test func aKeepReasonBlocksTheDiscard() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = LifecycleDeadlineRig()
        let lifecycle = PageLifecycle(conditions: .discarding(), deadlines: rig.scheduler)
        let view = try makeView(nil)
        defer { view.close() }
        view.loaded = true
        let target = PageWebViewLifecycle(view, encoder: decoder)
        lifecycle.hide("tab", page: target)
        lifecycle.setKeepReasons([.userEdits], for: "tab")
        rig.advance(to: .seconds(900))
        lifecycle.runPass()
        #expect(lifecycle.state(of: "tab") != .discarded)
        #expect(!view.isDiscarded)

        lifecycle.setKeepReasons([], for: "tab")
        lifecycle.runPass()
        #expect(lifecycle.state(of: "tab") == .discarded)
        #expect(view.isDiscarded)

        lifecycle.show("tab", page: target)
        #expect(lifecycle.state(of: "tab") == .active)
        #expect(!view.isDiscarded)
    }

    /// What a hide keeps (PageWebView+Snapshot.swift): the encoded picture and the state the page posted.
    private static func keepHide(_ view: PageWebView, state: String?) {
        view.hideState.captured(view.hideState.beginCapture(), encoded: encoded)
        view.hideState.saveState(state ?? PageHideState.noStateText)
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        return try #require(context.makeImage())
    }
}

/// A provider whose streams count while they live: the router's cancel ends one.
@MainActor
private final class LiveSubscriptions: PageProvider {
    private(set) var live = 0

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .null }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        live += 1
        return PageSubscription(frozenDelivery: .resync) { [weak self] in self?.live -= 1 }
    }
}
