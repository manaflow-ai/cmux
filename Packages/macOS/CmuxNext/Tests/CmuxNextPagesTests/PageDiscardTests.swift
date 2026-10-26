import AppKit
import CmuxNextCompat
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
    private final class RecordingEncoder {
        var images: [CGImage] = []
        var answer: PageEncodedSnapshot?

        var encoder: PageSnapshotEncoder {
            PageSnapshotEncoder { [self] image, done in
                images.append(image)
                done(answer)
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

    @Test func aPageKeepsTheStateItPostsWhenItHides() throws {
        let root = try pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/", chromium: nil))
        let post = try #require(view.chromiumMessageHandlers[PageWebView.pageStateHandler], "no state handler installed")
        post(#"{"scroll":120}"#)
        #expect(view.hideState.savedState == #"{"scroll":120}"#)
        post(String(repeating: "x", count: PageHideState.maxStateBytes + 1))
        #expect(view.hideState.savedState == nil, "an oversized state replaced nothing and was kept")
        post(#"{"scroll":0}"#)
        post(["not": "text"])
        #expect(view.hideState.savedState == nil)
        view.close()
    }

    // MARK: The picture's state

    /// WebKit's frame is kept as drawn; only the discard encodes it.
    @Test func aFrameIsEncodedOnlyWhenTheDiscardComes() throws {
        let state = PageHideState()
        let encoder = RecordingEncoder()
        encoder.answer = Self.picture
        let frame = try image()
        state.captured(state.beginCapture(), .frame(frame))
        #expect(state.keepsFrame)
        #expect(encoder.images.isEmpty)
        state.encodeForDiscard(with: encoder.encoder)
        #expect(encoder.images.count == 1)
        #expect(state.encoded == Self.picture)
        #expect(!state.keepsFrame, "the decoded frame stayed after its encode")
        state.encodeForDiscard(with: encoder.encoder)
        #expect(encoder.images.count == 1, "an encoded picture was encoded again")
    }

    @Test func aDiscardBeforeThePictureComesEncodesItWhenItComes() throws {
        let state = PageHideState()
        let encoder = RecordingEncoder()
        encoder.answer = Self.picture
        let capture = state.beginCapture()
        state.encodeForDiscard(with: encoder.encoder)
        #expect(encoder.images.isEmpty)
        state.captured(capture, .frame(try image()))
        #expect(encoder.images.count == 1)
        #expect(state.encoded == Self.picture)
    }

    @Test func aPictureThatComesAfterTheShowIsDropped() throws {
        let state = PageHideState()
        let capture = state.beginCapture()
        state.drop()
        state.captured(capture, .frame(try image()))
        #expect(!state.keepsFrame)
        let newer = state.beginCapture()
        state.captured(capture, .encoded(Self.picture))
        #expect(state.encoded == nil, "an older capture's answer replaced the newer one")
        state.captured(newer, .encoded(Self.picture))
        #expect(state.encoded == Self.picture)
    }

    /// The app's encoder runs the encode on a lane at QoS utility, never on the main thread, and makes
    /// a PNG of the frame's size.
    @Test func theAppEncoderEncodesOnAUtilityLane() async throws {
        let (seen, report) = AsyncStream<(onMain: Bool, qos: UInt32, snapshot: PageEncodedSnapshot?)>.makeStream()
        let encoder = PageSnapshotEncoder(work: BackgroundWork(cpuWidth: 1, label: "test.page-snapshot"), mainWork: rig.work) { image in
            let snapshot = PageSnapshotEncoder.png(image)
            report.yield((Thread.isMainThread, qos_class_self().rawValue, snapshot))
            return snapshot
        }
        encoder.encode(try image(width: 6, height: 5)) { _ in }
        var iterator = seen.makeAsyncIterator()
        let run = try #require(await iterator.next())
        #expect(!run.onMain)
        #expect(run.qos == QOS_CLASS_UTILITY.rawValue)
        let snapshot = try #require(run.snapshot)
        #expect(snapshot.pixelSize == CGSize(width: 6, height: 5))
        let decoded = try #require(CGImageSourceCreateWithData(snapshot.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(decoded.width == 6 && decoded.height == 5)
        #expect(decoded.alphaInfo != .none && decoded.alphaInfo != .noneSkipLast && decoded.alphaInfo != .noneSkipFirst, "the PNG lost its alpha")
    }
}
