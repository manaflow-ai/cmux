import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextMemory
@testable import CmuxNextPages
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// Overlay and made-ahead pages (`ContentKind.overlayPage`, feature `memoryOverlayPagesOnFirstUse`):
/// none is made before its first open, and the App's one overlay page planner (``OverlayPageDiscards`` over the
/// ``ContentDiscardScheduler`` every kind goes through) lets a closed one go after its release time as the Memory
/// Saver mode scales it, or on the urgent pace from warning pressure on; the next open makes it again. Time and
/// pressure are the ``OverlayPagePlannerRig``'s.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OverlayPageReleaseTests {
    /// Content that counts its drops and can be held in use.
    @MainActor private final class Content {
        var busy = false
        private(set) var dropped = 0
        func drop() { dropped += 1 }
    }

    private static func release(_ content: Content, planner: OverlayPagePlannerRig) -> OverlayPageRelease {
        planner.terms().release(owner: "test", inUse: { content.busy }) { content.drop() }
    }

    // MARK: The release on the planner

    @Test func noPrewarmBeforeTheFirstShowAndNoneAgainAfterARelease() async {
        let content = Content()
        let planner = OverlayPagePlannerRig()
        let release = Self.release(content, planner: planner)
        #expect(!release.allowsPrewarm, "a launch warm-up may make the content before anyone opened it")
        release.didShow()
        #expect(release.allowsPrewarm)
        release.didMake()
        release.didHide()
        await planner.pass(301)
        #expect(content.dropped == 1 && release.releases == 1)
        #expect(!release.allowsPrewarm, "a warm-up may remake released content with no open")
        #expect(planner.scheduler.discardedCount == 1, "the release is not counted as an overlay page discard")
    }

    @Test func closedContentGoesFiveMinutesAfterItsCloseAndAnOpenCallsItOff() async {
        let content = Content()
        let planner = OverlayPagePlannerRig()
        let release = Self.release(content, planner: planner)
        release.didShow()
        release.didMake()
        #expect(!planner.scheduler.hasDeadline, "a release was armed while the content shows")
        release.didHide()
        #expect(planner.scheduler.nextCheck == 300, "no release five minutes after the close")

        await planner.pass(200)
        release.didShow()
        #expect(!planner.scheduler.hasDeadline, "an open did not call the release off")
        release.didHide()
        await planner.pass(200)
        #expect(content.dropped == 0, "the release counted from the first close, not the last")

        await planner.pass(101)
        #expect(content.dropped == 1 && !release.isHolding)
        #expect(!planner.scheduler.hasDeadline, "a deadline stayed armed with nothing held")
    }

    @Test func contentStillInUseIsKeptAndLookedAtOneReleaseTimeLater() async {
        let content = Content()
        let planner = OverlayPagePlannerRig()
        let release = Self.release(content, planner: planner)
        release.didShow()
        release.didMake()
        release.didHide()
        content.busy = true  // still fading out, or its sheet shows
        await planner.pass(301)
        #expect(content.dropped == 0 && release.isHolding)
        #expect(planner.scheduler.exemptions[release.key] == .visible, "the planner does not say why the content stays")
        #expect(planner.scheduler.nextCheck == 300, "content in use is looked at again after \(planner.scheduler.nextCheck ?? -1) s")
        content.busy = false
        await planner.pass(300)
        #expect(content.dropped == 1)
    }

    @Test func warningPressureReleasesHiddenContentTenSecondsAfterItsCloseAndKeepsShownContent() async {
        let content = Content()
        let planner = OverlayPagePlannerRig(level: .warning)
        let release = Self.release(content, planner: planner)
        release.didShow()
        release.didMake()
        await planner.pass(60)
        #expect(content.dropped == 0, "pressure released content that shows")

        release.didHide()
        #expect(content.dropped == 0, "the close released the content in its own turn")
        #expect(planner.scheduler.nextCheck == 10, "the urgent pace's 10 s hidden")
        await planner.pass(11)
        #expect(content.dropped == 1, "hidden content was kept at warning pressure")
    }

    @Test func theReleaseTimeFollowsTheMemorySaverMode() async {
        let content = Content()
        let planner = OverlayPagePlannerRig()
        let release = Self.release(content, planner: planner)
        planner.scheduler.memorySaverModeDidChange(.off)
        release.didShow()
        release.didMake()
        release.didHide()
        await planner.pass(3_600)
        #expect(content.dropped == 0, "Memory Saver off released an overlay page proactively")

        planner.scheduler.memorySaverModeDidChange(.aggressive)
        release.didShow()
        release.didHide()
        await planner.pass(151)
        #expect(content.dropped == 1, "aggressive Memory Saver kept a closed overlay page past half its release time")
    }

    @Test func theAppCountsOverlayPageDiscardsOnlyWhileAFeatureReleasesThem() {
        #expect(MemoryHistograms.discardKinds(overlayPages: true).contains(ContentKind.overlayPage.rawValue))
        #expect(!MemoryHistograms.discardKinds(overlayPages: false).contains(ContentKind.overlayPage.rawValue))
    }

    // MARK: The icon picker

    /// An anchor in no window: the picker opens without showing its panel.
    private static let anchor = IconPickerService.Anchor(view: NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)),
                                                         rect: NSRect(x: 10, y: 10, width: 2, height: 2))

    /// Opens the picker and waits for the open's timing (a first open loads the catalog off the main actor).
    private static func open(_ picker: IconPickerService) async -> IconPickerOpenTiming {
        await withCheckedContinuation { (done: CheckedContinuation<IconPickerOpenTiming, Never>) in
            picker.onOpened = { [weak picker] timing in
                picker?.onOpened = nil
                done.resume(returning: timing)
            }
            picker.pick(current: nil, target: "workspace:1", at: anchor) { _ in }
        }
    }

    @Test func theIconPickerMakesNoPageAtLaunchAndLetsItGoFiveMinutesAfterItsClose() async throws {
        let rig = MainDeadlineRig()
        let retirer = PageRetirer(deadlines: rig.deadlines)
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: ManualMemoryLevelRegistry(), retirer: retirer)
        let planner = OverlayPagePlannerRig()
        let picker = IconPickerService(services: nil, webUI: host, mainWork: MainWorkScheduler(budget: MainFrameBudget()), release: planner.terms())

        // The launch's afterStartup post (LaunchFirstOpenWarmups) at Home idle.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(!picker.isWarm, "the launch made the icon picker with no open")
        #expect(host.openPages.isEmpty, "an icon picker page exists at Home idle without an open")

        let first = await Self.open(picker)
        #expect(first.createdPage)
        weak var page: PageWebView?
        page = try #require(picker.open?.page)
        #expect(!planner.scheduler.hasDeadline, "a release was armed while the picker shows")

        picker.open?.provider.finish(.cancel)
        #expect(picker.open == nil && picker.isWarm, "the close dropped the page at once")
        #expect(planner.scheduler.nextCheck == 300, "no release five minutes after the close")

        await planner.pass(301)
        autoreleasepool { retirer.closeRetired() }
        #expect(!picker.isWarm, "the unused picker was kept past its release time")
        #expect(host.openPages.isEmpty)
        #expect(page == nil, "the released picker's page is still alive")

        // The next open works and makes the page again (its timing says so).
        let again = await Self.open(picker)
        #expect(again.createdPage, "the open after a release reused a page that should have gone")
        #expect(picker.isWarm && host.openPages.count == 1)
    }

    // MARK: The Extensions bubble

    private static func extensionsTab() -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        tab.showsExtensionToolbar = true
        tab.extensionBackend.extensions = (0..<3).map { BrowserExtensionInfo(id: "ext\($0)", name: "Extension \($0)", hasAction: true) }
        tab.extensionStore.refresh()
        return tab
    }

    @Test func theExtensionsBubbleBuildsNoRowsBeforeItsFirstOpen() throws {
        let controller = ExtensionsMenuController(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        controller.releaseWhenUnused(OverlayPagePlannerRig().terms())
        controller.prepare(host: Self.extensionsTab())  // the toolbar's idle prepare once a tab binds
        #expect(controller.content.rows.isEmpty, "a pane whose bubble never opened built its rows")
    }

    /// The bubble's own open and close drive its release (a bubble needs a screen to show).
    @Test(.enabled("a bubble needs a screen to show") { await !NSScreen.screens.isEmpty })
    func theExtensionsBubblesOpenAndCloseDriveItsRelease() async throws {
        let planner = OverlayPagePlannerRig()
        let controller = ExtensionsMenuController(mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        controller.releaseWhenUnused(planner.terms())
        let tab = Self.extensionsTab()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 560, y: 460, width: 28, height: 28))
        window.contentView?.addSubview(anchor)
        window.orderFrontRegardless()
        let handler = ExtensionsMenu.DirectHandler(host: tab) { _ in }

        controller.show(host: tab, handler: handler, anchor: anchor)
        try #require(controller.isShown, "the bubble did not show")
        #expect(controller.content.rows.count == 3)
        #expect(!planner.scheduler.hasDeadline, "a release was armed while the bubble shows")
        controller.close()
        #expect(planner.scheduler.nextCheck == 300, "the close armed no release")
        controller.prepare(host: tab)
        #expect(controller.content.rows.count == 3, "a pane whose bubble opened no longer builds its rows ahead")

        await planner.pass(301)
        #expect(controller.content.rows.isEmpty, "the unused bubble kept its rows")
        controller.prepare(host: tab)
        #expect(controller.content.rows.isEmpty, "a released bubble rebuilt its rows with no open")
        controller.show(host: tab, handler: handler, anchor: anchor)
        #expect(controller.content.rows.count == 3, "the open after a release did not build the rows")
        controller.close()
    }

    // MARK: The update card's highlights

    /// The page is made on the hover, held for the release only once it measured itself (so pressure at the card's
    /// show cannot end it before it could open), and made again in the card's view after a release.
    @Test func theHighlightsPageIsMadeOnTheHoverAndMadeAgainAfterAWarningRelease() async throws {
        let planner = OverlayPagePlannerRig(level: .warning)
        let services = Self.services()  // the island holds it weakly
        let island = UpdateSurfaceIsland(kind: .ready, services: services, release: planner.terms())
        defer { island.close(); withExtendedLifetime(services) {} }
        #expect(island.page == nil, "the highlights page was made before the first hover")
        var heights = 0
        island.onHeightChange = { heights += 1 }

        island.didPark()  // the card parks the view
        island.willShow()  // the first hover
        let first = try #require(island.page, "the hover made no page")
        #expect(first.superview === island.view && island.lifecycleKey != nil)
        await planner.pass(60)
        #expect(island.page === first, "warning pressure ended the page before it measured itself")

        island.provider.onHeight?(240)
        #expect(island.contentHeight > 0 && heights == 1, "the page's height did not reach the card")
        island.didShow()  // the popup opens
        await planner.pass(60)
        #expect(island.page === first, "pressure released the highlights while they show")

        island.didPark()  // the popup closed
        await planner.pass(11)
        #expect(island.page == nil && island.lifecycleKey == nil, "hidden highlights were kept at warning pressure")
        #expect(island.contentHeight == 0 && first.superview == nil)

        island.willShow()  // the next hover
        let again = try #require(island.page, "the hover after a release made no page")
        #expect(again !== first && again.superview === island.view && island.lifecycleKey != nil)
        island.provider.onHeight?(240)
        #expect(island.contentHeight > 0 && heights == 2, "the remade page's height did not reach the card")
    }

    /// A highlights surface whose page the hover makes; the test measures it.
    @MainActor private final class LazyHighlights: SidebarSurfaceIsland {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        var contentHeight: CGFloat = 0
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        private(set) var asked = 0
        private(set) var shows = 0
        func close() {}
        func willShow() { if contentHeight == 0 { asked += 1 } }
        func didShow() { shows += 1 }
        func measure(_ height: CGFloat) {
            contentHeight = height
            onHeightChange?()
        }
    }

    @Test func theCardAsksForItsHighlightsOnTheHoverAndOpensThemOnceMeasured() async throws {
        let h = try await UpdateCardHoverParityTests().make()
        defer { h.tearDown() }
        try #require(!h.card.isHidden, "the staged update shows no card")
        let highlights = LazyHighlights()
        h.card.highlights = highlights

        h.card.showNotes()  // the hover
        #expect(highlights.asked == 1, "the hover did not ask for the page")
        #expect(!h.card.notesAreShown && highlights.shows == 0, "a popup opened before the page measured itself")
        highlights.measure(240)
        h.card.showNotes()  // the pointer's next move over the card
        #expect(h.card.notesAreShown && highlights.shows == 1, "the measured highlights did not open")
    }

    // MARK: The app's wiring

    private static func services(enabling names: Set<String> = []) -> AppServices {
        _ = NSApplication.shared
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: FeatureOverrides(environmentEnabled: names))
        return AppServices(environment: AppEnvironment.current([:]), features: features)
    }

    @Test func theFeatureHandsTheTermsToTheIconPickerAndTheUpdateHighlightsOnly() throws {
        let on = Self.services(enabling: [Feature.memoryOverlayPagesOnFirstUse.name])
        let terms = try #require(on.overlayPageRelease)
        #expect(terms.releaseAfter == OverlayPageRelease.defaultReleaseAfter)
        #expect(terms.planner === on.overlayPageDiscards, "the terms are not on the app's one overlay page planner")
        #expect(on.overlayPageDiscards.scheduler.kind == .overlayPage && on.overlayPageDiscards.scheduler.urgentAtWarning)
        #expect(on.iconPicker.release != nil, "the icon picker is kept for good with the feature on")
        let islands = UpdateSurfaceIslands(services: on)
        let ready = try #require(islands.island(.ready) as? UpdateSurfaceIsland)
        let updated = try #require(islands.island(.updated) as? UpdateSurfaceIsland)
        defer { ready.close(); updated.close() }
        #expect(ready.release != nil, "the highlights page is kept for good")
        #expect(ready.page == nil, "the highlights page was made at the card's show, before any hover")
        #expect(updated.release == nil && updated.page != nil, "the shown Updated card's page has a release")

        let off = Self.services()
        #expect(!off.features.isEnabled(.memoryOverlayPagesOnFirstUse), "the feature must default off")
        #expect(off.overlayPageRelease == nil && off.iconPicker.release == nil)
        let offReady = try #require(UpdateSurfaceIslands(services: off).island(.ready) as? UpdateSurfaceIsland)
        defer { offReady.close() }
        #expect(offReady.release == nil && offReady.page != nil, "with the feature off the card's show no longer makes the page")
    }

    @Test func withoutTheFeatureTheIconPickerStaysWarmAfterItsClose() async {
        let picker = IconPickerService(services: nil, webUI: .iconPickerTestHost(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(picker.isWarm, "the launch no longer warms the picker with the feature off")
        let timing = await Self.open(picker)
        #expect(!timing.createdPage)
        picker.open?.provider.finish(.cancel)
        #expect(picker.isWarm && picker.release == nil)
    }
}
