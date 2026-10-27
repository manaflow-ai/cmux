import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextHibernation
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p04-input-042's prewarm kinds, through the app's hibernation as the intent prewarm's warmer:
/// - a hibernated target's cover is decoded off the main thread before its hidden restore, so the restored
///   page's cover has pixels out of a window (it would otherwise decode, 10 to 30 ms, on the switch's frames);
/// - a hibernated target is restored at the size it shows at (its pane's content size, else its view's size
///   when it slept), so it lays out hidden, not on the switch's frame;
/// - a cancel drops both and the restore never starts;
/// - a prewarmed page that sleeps again (the hibernation's grace) leaves the FIFO, and the next press on it
///   prewarms it again; nothing runs on the press's own turn.
/// Real WebKit pages.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct IntentPrewarmKindsTests {
    /// A page whose first paint comes 1.5 s after it loads, so its cover stays while the test reads it.
    private static let slowPaint = """
        <script>const until = Date.now() + 1500; while (Date.now() < until) {}</script><p>painted</p>
        """

    // MARK: The kinds' state

    @Test func theRestoreTakesTheDecodedCoverAndTheSizeOnce() throws {
        var kinds = IntentPrewarmKinds()
        let cover = try #require(Self.picture())
        kinds.target("a", size: CGSize(width: 640, height: 420))
        let ticket = kinds.beginDecode("a")
        let kept1 = kinds.decoded("a", cover, ticket: ticket)
        #expect(kept1)
        #expect(kinds.decodes.isEmpty)
        let taken = kinds.takeForRestore("a")
        #expect(taken.cover === cover)
        #expect(taken.size == CGSize(width: 640, height: 420))
        let again = kinds.takeForRestore("a")
        #expect(again.cover == nil && again.size == nil)
    }

    @Test func aCancelDropsTheCoverAndTheSizeAndMakesTheDecodeStale() throws {
        var kinds = IntentPrewarmKinds()
        let cover = try #require(Self.picture())
        kinds.target("a", size: CGSize(width: 640, height: 420))
        let stale = kinds.beginDecode("a")
        kinds.cancel("a")
        #expect(kinds.decodes.isEmpty && kinds.covers.isEmpty && kinds.sizes.isEmpty)
        let kept2 = kinds.decoded("a", cover, ticket: stale)
        #expect(!kept2, "a cancelled decode's reply was kept")
        #expect(kinds.covers.isEmpty)
        let current = kinds.beginDecode("a")
        let kept3 = kinds.decoded("a", cover, ticket: stale)
        #expect(!kept3, "an older decode's reply was kept")
        let kept4 = kinds.decoded("a", cover, ticket: current)
        #expect(kept4)
    }

    @Test func aSleepRecordsTheViewsSizeUntilTheRestoreOrTheClose() {
        var kinds = IntentPrewarmKinds()
        kinds.slept("a", size: CGSize(width: 800, height: 500))
        kinds.slept("b", size: .zero)
        #expect(kinds.sleptSizes == ["a": CGSize(width: 800, height: 500)], "a view never laid out has no size to keep")
        _ = kinds.takeForRestore("a")
        #expect(kinds.sleptSizes.isEmpty, "a live page needs no slept size")
        kinds.slept("a", size: CGSize(width: 800, height: 500))
        kinds.forget("a")
        #expect(kinds.sleptSizes.isEmpty)
    }

    // MARK: Cover decode

    @Test func aHibernatedTargetsCoverDecodesBeforeItsRestoreAndCoversThePageOutOfAWindow() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await Self.hibernated(rig, "cover", size: CGSize(width: 640, height: 420))
        var atSwap: (covered: Bool, inWindow: Bool)?
        let previous = rig.services.cache.onBrowserReady
        rig.services.cache.onBrowserReady = { [weak cache = rig.services.cache] ready in
            previous?(ready)
            guard ready == key, atSwap == nil, let page = cache?.browsers[ready]?.tab as? WebKitTab else { return }
            atSwap = (Self.cover(over: page) != nil, page.contentView.window != nil)
        }
        rig.hibernation.startPrewarm(key, trigger: .pointerDown)
        #expect(rig.isHibernated(key), "the restore waits for the cover's decode")
        #expect(rig.hibernation.prewarmKinds.decodes[key] != nil, "the cover decodes off the main thread")
        try await rig.until("the prewarm restored the page") { atSwap != nil }
        #expect(atSwap?.inWindow == false, "a prewarm restores hidden")
        #expect(atSwap?.covered == true, "the restored page's cover has no pixels out of a window: it would decode on the switch")
        #expect(rig.hibernation.prewarmKinds.covers[key] == nil, "the restore took the cover")
    }

    @Test func aCancelBeforeTheCoverLandsDropsItAndRestoresNothing() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await Self.hibernated(rig, "cancel", size: CGSize(width: 640, height: 420))
        rig.hibernation.startPrewarm(key, trigger: .pointerDown)
        rig.hibernation.cancelPrewarm(key)
        #expect(rig.hibernation.prewarmKinds.decodes.isEmpty && rig.hibernation.prewarmKinds.sizes.isEmpty)
        // Long past a 400 x 300 decode.
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.isHibernated(key), "a cancelled prewarm restored its page")
        #expect(rig.hibernation.prewarmKinds.covers.isEmpty)
    }

    // MARK: Target geometry

    @Test func aHibernatedTargetIsRestoredAtTheSizeItSleptAt() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await Self.hibernated(rig, "slept", size: CGSize(width: 640, height: 420))
        rig.hibernation.startPrewarm(key, trigger: .pointerDown)
        try await rig.until("the prewarm restored the page") { !rig.isHibernated(key) }
        let page = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        #expect(page.contentView.window == nil)
        #expect(page.contentView.frame.size == CGSize(width: 640, height: 420), "the restored page lays out on the switch's frame")
    }

    @Test func aTargetItsPaneListsIsRestoredAtThePanesContentSize() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let key = try await Self.hibernated(rig, "pane", size: CGSize(width: 640, height: 420))
        let pane = SizedPane(size: CGSize(width: 900, height: 700))
        rig.services.cache.presenters[ObjectIdentifier(pane)] = WeakPresenter(value: pane)
        rig.hibernation.paneDidChange(ObjectIdentifier(pane), order: [key], selected: nil)
        rig.hibernation.startPrewarm(key, trigger: .pointerDown)
        try await rig.until("the prewarm restored the page") { !rig.isHibernated(key) }
        let page = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        #expect(page.contentView.frame.size == CGSize(width: 900, height: 700), "the pane resized since the page slept")
        rig.hibernation.paneDidGo(ObjectIdentifier(pane))
    }

    // MARK: Press and grace

    /// The press's turn leaves the frozen page frozen; the press deadline thaws it; the hibernation's grace
    /// freezes it again, which spends the prewarm, so the next press on it prewarms it again.
    @Test func aPressThawsOnTheDeadlineAndAPageThatFreezesAgainIsPrewarmedAgain() async throws {
        let rig = try NeighborTabsWakeTests.Rig()
        defer { rig.close() }
        var setting = rig.hibernation.setting
        setting.neighborRadius = 0
        rig.hibernation.apply(setting)
        let keys = try await rig.pages(["a", "b", "c"])
        try await rig.until("every hidden page freezes") { keys.allSatisfy(rig.hibernation.frozen.contains) }
        rig.show(keys[0], order: keys)

        let deadlines = MainDeadlineRig()
        let service = IntentPrewarmService<String>(
            warmer: rig.hibernation, memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
            dwellTimer: MainDeadline(owner: "IntentPrewarm.hoverDwell", workClass: .background, scheduler: deadlines.deadlines),
            pressStart: MainDeadline(owner: "IntentPrewarm.pressStart", workClass: .background, scheduler: deadlines.deadlines))
        rig.hibernation.intentPrewarm = (service, rig.services.energyMonitor.follow { _ in })

        service.pointerPressed(on: keys[2])
        #expect(rig.hibernation.frozen.contains(keys[2]), "the press's input turn thawed the page")
        #expect(service.queue.held == [keys[2]])
        deadlines.fireAndRun()
        #expect(!rig.hibernation.frozen.contains(keys[2]))

        rig.hibernation.replan()
        try await rig.until("the prewarmed page freezes again") { rig.hibernation.frozen.contains(keys[2]) }
        #expect(service.queue.held.isEmpty, "the spent prewarm still holds a slot")

        service.pointerPressed(on: keys[2])
        deadlines.fireAndRun()
        #expect(!rig.hibernation.frozen.contains(keys[2]), "the second press did not prewarm the page again")
        #expect(service.counters.started[.pointerDown] == 2)
        rig.show(keys[2], order: keys)
        #expect(service.counters.hits[.pointerDown] == 1, "only the live prewarm is a hit")
    }

    // MARK: Rig

    /// A presenter whose content area is `size`.
    @MainActor final class SizedPane: SurfacePresenter {
        let size: CGSize
        init(size: CGSize) { self.size = size }
        func surfaceWasDisplaced(_ key: String) {}
        var presentedContentSize: CGSize? { size }
    }

    /// A slow-painting page laid out at `size`, shown, hidden and hibernated with a picture; pressure back to
    /// normal so its wake is not hibernated again while the test reads it.
    private static func hibernated(_ rig: HiddenPageHibernationTests.Rig, _ name: String, size: CGSize) async throws -> String {
        rig.hibernation.standInClock = ManualClock()
        // The composition root's decoder: the `.cpu` lane, a background-class reply.
        rig.hibernation.prewarmKinds.decodeCover = { [weak services = rig.services] picture, landed in
            services?.decodePrewarmCover(picture, landed: landed)
        }
        let picture = try #require(Self.picture())
        rig.hibernation.capture = { _ in picture }
        let page = try await rig.page(name, body: Self.slowPaint)
        page.contentView.setFrameSize(size)
        let key = try await rig.hide(page)
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))
        rig.hibernation.pressureDidChange(.normal)
        return key
    }

    /// An image view with pixels over the whole page, above the web view.
    private static func cover(over page: WebKitTab) -> NSImageView? {
        guard let index = page.contentView.subviews.firstIndex(where: { $0 === page.webView }) else { return nil }
        return page.contentView.subviews[(index + 1)...].compactMap { $0 as? NSImageView }.first { !$0.isHidden && $0.image != nil }
    }

    private static func picture() -> CGImage? {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return context?.makeImage()
    }
}
