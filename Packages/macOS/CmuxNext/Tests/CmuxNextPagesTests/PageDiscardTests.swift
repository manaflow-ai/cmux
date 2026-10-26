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
import Foundation
import ImageIO
import Testing

/// A page keeps its picture and its state from the turn it hides, and a discard makes no call into the
/// page (p13-webui-088): a frozen page cannot answer, so the old design's discard-time save call kept a
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
        func freeze() { page.lines.append("freeze \(name)") }
        func thaw() { page.lines.append("thaw \(name)") }
        func discard() { page.lines.append("discard \(name)") }
    }

    /// An encoder that records what it is given and answers at once with ``answer``.
    @MainActor private final class RecordingEncoder {
        var images: [CGImage] = []
        var answer: PageEncodedSnapshot?

        var encoder: PageSnapshotEncoder {
            PageSnapshotEncoder { [self] image, done in
                images.append(image)
                done(answer)
            }
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

    init() {
        lifecycle = PageLifecycle(deadlines: rig.scheduler)
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
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: hosting))
        view.chromiumClock = PageTestClock.never
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

    /// A Chromium page copies its surface when it hides (no DevTools), and the discard 300 s later makes
    /// no call into the page and encodes nothing more: Chromium's copy comes encoded.
    @Test func aChromiumPageKeepsItsSurfaceCopyAtTheHideAndIsDiscardedWithNoPageCall() async throws {
        let root = try pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await chromiumView(root: root)
        let (other, _) = try await chromiumView(root: root)
        page.surfaceCopy = Self.picture
        let encoder = RecordingEncoder()
        let calls = page.calls.count, evaluations = page.evaluations.count
        lifecycle.hide("a", page: PageWebViewLifecycle(view, encoder: encoder.encoder))
        #expect(page.surfaceCopies == [CGSize(width: 200, height: 160)], "one copy at the view's 2x size, in the hide's turn")
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
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil))
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
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil))
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
