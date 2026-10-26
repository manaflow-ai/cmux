import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
@testable import CmuxNextPages
import CmuxNextWakeups
import Foundation
import Testing

/// Overlay and made-ahead pages (`ContentKind.overlayPage`, feature `memoryOverlayPagesOnFirstUse`, p07-memory-086):
/// none is made before its first open, a closed one goes five minutes after its close on one background deadline,
/// a hidden one goes at warning pressure, and the next open makes it again. The deadlines fire on a hand-fired
/// ``MainDeadlineRig``; the pressure comes from a ``ManualMemoryLevelRegistry``.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OverlayPageReleaseTests {
    /// Content that counts its releases and can be held busy.
    @MainActor private final class Content {
        var busy = false
        private(set) var released = 0
        func release() -> Bool {
            guard !busy else { return false }
            released += 1
            return true
        }
    }

    private static let releaseAfter = OverlayPageRelease.defaultReleaseAfter

    private static func release(_ content: Content, rig: MainDeadlineRig, memory: ManualMemoryLevelRegistry? = nil) -> OverlayPageRelease {
        OverlayPageReleaseTerms(deadlines: rig.deadlines, memory: memory).release(owner: "test") { content.release() }
    }

    /// Whether the rig's next wake is the release, `releaseAfter` from now.
    private static func releaseIsDue(_ rig: MainDeadlineRig) -> Bool {
        guard let next = rig.deadlines.nextFire else { return false }
        return next >= releaseAfter && next <= releaseAfter + .seconds(1)
    }

    // MARK: The release

    @Test func noPrewarmBeforeTheFirstShowAndNoneAgainAfterARelease() {
        let content = Content()
        let rig = MainDeadlineRig()
        let release = Self.release(content, rig: rig)
        #expect(!release.allowsPrewarm, "a launch warm-up may make the content before anyone opened it")
        release.didShow()
        #expect(release.allowsPrewarm)
        release.didMake()
        release.didHide()
        rig.fireAndRun()
        #expect(content.released == 1)
        #expect(!release.allowsPrewarm, "a warm-up may remake released content with no open")
    }

    @Test func closedContentGoesFiveMinutesAfterItsCloseAndAnOpenCallsItOff() {
        let content = Content()
        let rig = MainDeadlineRig()
        let release = Self.release(content, rig: rig)
        release.didShow()
        release.didMake()
        #expect(rig.deadlines.nextFire == nil, "a release was armed while the content shows")
        release.didHide()
        #expect(Self.releaseIsDue(rig), "no one-shot release five minutes after the close")

        rig.advance(by: .seconds(200))
        release.didShow()
        #expect(!release.isReleasePending, "an open did not call the release off")
        release.didHide()
        #expect(Self.releaseIsDue(rig), "the second close did not start the five minutes again")

        rig.fireAndRun()
        #expect(content.released == 1 && !release.isHolding)
        #expect(rig.deadlines.nextFire == nil, "a deadline stayed armed with nothing held")
    }

    @Test func contentStillInUseIsKeptAndLookedAtAgain() {
        let content = Content()
        let rig = MainDeadlineRig()
        let release = Self.release(content, rig: rig)
        release.didShow()
        release.didMake()
        release.didHide()
        content.busy = true  // still fading out, or its sheet shows
        rig.fireAndRun()
        #expect(content.released == 0 && release.isHolding)
        #expect(Self.releaseIsDue(rig), "content in use at its deadline was not looked at again")
        content.busy = false
        rig.fireAndRun()
        #expect(content.released == 1)
    }

    @Test func warningPressureReleasesHiddenContentAtTheNextFireAndKeepsShownContent() {
        let content = Content()
        let rig = MainDeadlineRig()
        let memory = ManualMemoryLevelRegistry()
        let release = Self.release(content, rig: rig, memory: memory)
        #expect(memory.liveCount == 1, "the release is not a memory consumer")
        release.didShow()
        release.didMake()

        memory.send(.warning)
        #expect(content.released == 0, "pressure released content in the turn of the level change")
        #expect(rig.deadlines.nextFire == nil, "pressure armed a release for content that shows")

        release.didHide()
        #expect(content.released == 0, "the close released the content in its own turn")
        rig.fireAndRun()
        #expect(content.released == 1, "hidden content was kept at warning pressure")

        release.cancel()
        #expect(memory.liveCount == 0)
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
        let picker = IconPickerService(services: nil, webUI: host,
                                       release: OverlayPageReleaseTerms(deadlines: rig.deadlines, memory: nil))

        // The launch's afterStartup post (LaunchFirstOpenWarmups) at Home idle.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(!picker.isWarm, "the launch made the icon picker with no open")
        #expect(host.openPages.isEmpty, "an icon picker page exists at Home idle without an open")

        let first = await Self.open(picker)
        #expect(first.createdPage)
        weak var page: PageWebView?
        page = try #require(picker.open?.page)
        #expect(picker.release?.isReleasePending == false, "a release was armed while the picker shows")

        picker.open?.provider.finish(.cancel)
        #expect(picker.open == nil && picker.isWarm, "the close dropped the page at once")
        #expect(Self.releaseIsDue(rig), "no release five minutes after the close")

        autoreleasepool {
            rig.fireAndRun()
            retirer.closeRetired()
        }
        #expect(!picker.isWarm, "the unused picker was kept past its deadline")
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

    /// The bubble's open and close are its release's show and hide (a bubble needs a screen to show; its open on
    /// one is ExtensionsMenuPerformanceTests'), so this drives them on the release.
    @Test func theExtensionsBubbleBuildsNoRowsBeforeItsFirstOpenAndDropsThemOnceUnused() throws {
        let rig = MainDeadlineRig()
        let controller = ExtensionsMenuController(mainWork: rig.work)
        controller.releaseWhenUnused(OverlayPageReleaseTerms(deadlines: rig.deadlines, memory: nil))
        let release = try #require(controller.release)
        let tab = Self.extensionsTab()

        controller.prepare(host: tab)  // the toolbar's idle prepare once a tab binds
        #expect(controller.content.rows.isEmpty, "a pane whose bubble never opened built its rows")

        release.didShow()  // the first open
        release.didHide()
        controller.prepare(host: tab)
        #expect(controller.content.rows.count == 3, "a pane whose bubble opened no longer builds its rows ahead")
        #expect(Self.releaseIsDue(rig), "no release five minutes after the close")

        rig.fireAndRun()
        #expect(controller.content.rows.isEmpty, "the unused bubble kept its rows")
        controller.prepare(host: tab)
        #expect(controller.content.rows.isEmpty, "a released bubble rebuilt its rows with no open")
    }

    // MARK: The app's wiring

    private static func services(enabling names: Set<String> = []) -> AppServices {
        _ = NSApplication.shared
        let features = FeatureList(registry: FeatureRegistry(), channel: .dev, overrides: FeatureOverrides(environmentEnabled: names))
        return AppServices(environment: AppEnvironment.current([:]), features: features)
    }

    @Test func theFeatureHandsTheTermsToTheIconPickerAndTheUpdateHighlightsOnly() {
        let on = Self.services(enabling: [Feature.memoryOverlayPagesOnFirstUse.name])
        let terms = on.overlayPageRelease
        #expect(terms?.releaseAfter == OverlayPageRelease.defaultReleaseAfter)
        #expect(on.iconPicker.release != nil, "the icon picker is kept for good with the feature on")
        let ready = UpdateSurfaceIsland(kind: .ready, services: on), updated = UpdateSurfaceIsland(kind: .updated, services: on)
        defer { ready.close(); updated.close() }
        #expect(ready.release != nil, "the parked highlights page is kept for good")
        #expect(updated.release == nil, "the shown Updated card's page has a release")

        let off = Self.services()
        #expect(!off.features.isEnabled(.memoryOverlayPagesOnFirstUse), "the feature must default off")
        #expect(off.overlayPageRelease == nil && off.iconPicker.release == nil)
        let offReady = UpdateSurfaceIsland(kind: .ready, services: off)
        defer { offReady.close() }
        #expect(offReady.release == nil)
    }

    @Test func withoutTheFeatureTheIconPickerStaysWarmAfterItsClose() async {
        let picker = IconPickerService(services: nil, webUI: .iconPickerTestHost())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in picker.prepare { done.resume() } }
        #expect(picker.isWarm, "the launch no longer warms the picker with the feature off")
        let timing = await Self.open(picker)
        #expect(!timing.createdPage)
        picker.open?.provider.finish(.cancel)
        #expect(picker.isWarm && picker.release == nil)
    }
}
