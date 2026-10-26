import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextPages
import Foundation
import Testing

/// Page tab discards (`memoryDiscardInternalPages`, p07-memory-022): a page tab hidden past its
/// provider's policy lets its view go through the content lifecycle (`hibernate` and its
/// `release` effect) and keeps the tab; its next show makes the view again (`restore`), under its
/// last picture, with its scroll put back. A keep reason holds it, and one one-shot deadline
/// says when to look again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct InternalPageDiscardTests {
    @Test func aHiddenPagePastItsPolicyLetsItsPageWebViewGoAndGetsItsScrollBack() async throws {
        let folder = try Self.pageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = ReportingPage {
            PageWebView(descriptor: PageDescriptor(id: "test.discard", resource: "discard", namespaces: []), root: folder, routes: []) ?? NSView()
        }
        let rig = Rig(provider)
        provider.reportedScroll = CGPoint(x: 0, y: 240)
        weak var page: PageWebView?
        do {
            let view = try #require(rig.pages.view(for: rig.key))
            page = try #require(view.content as? PageWebView)
            rig.show()
            #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
            rig.hide()
        }
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden)
        #expect(rig.discards.nextCheck == 600, "the policy's 10 minutes")

        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()

        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(rig.pages.existingView(rig.key) == nil)
        #expect(rig.pages.isDiscarded(rig.key))
        #expect(page == nil, "the discarded tab's PageWebView is still alive")
        #expect(provider.discarded == [rig.key])
        #expect(rig.discards.discardedCount == 1)
        #expect(rig.pages.stripItem(rig.key).title == provider.title, "the tab keeps its title")

        // Its last picture (the page never painted here, so the test puts one in the previews).
        rig.cache.previews.insert(try #require(Self.picture()), for: rig.key)
        // Shown again: the pane makes the view first, then presents it.
        let rebuilt = try #require(rig.pages.view(for: rig.key))
        #expect(rebuilt.picture != nil, "the rebuilt page shows its last picture until it paints")
        #expect(!rebuilt.awaitsFirstPaint, "the picture is its first frame: the pane does not hold the old tab")
        rig.show()
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(provider.made == 2)
        #expect(provider.restored.isEmpty, "restored before the view has a size")
        rebuilt.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        rebuilt.layoutSubtreeIfNeeded()
        #expect(provider.restored.map(\.scroll) == [CGPoint(x: 0, y: 240)])
    }

    @Test func theDefaultViewStateKeepsANativePagesScroll() async throws {
        let rig = Rig(DefaultStatePage { Self.scrollingContent() })
        do {
            let view = try #require(rig.pages.view(for: rig.key))
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            view.layoutSubtreeIfNeeded()
            let scroll = try #require(view.content.firstScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            scroll.reflectScrolledClipView(scroll.contentView)
            rig.show()
            rig.hide()
        }
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil)

        let rebuilt = try #require(rig.pages.view(for: rig.key))
        rebuilt.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        rebuilt.layoutSubtreeIfNeeded()
        let scroll = try #require(rebuilt.content.firstScrollView)
        #expect(scroll.documentVisibleRect.origin.y == 500)
        #expect(rebuilt.picture == nil, "native content draws at once: no cover")
    }

    @Test func aKeepReasonHoldsTheViewAndIsAskedAgainOnePolicyTimeLater() async throws {
        let rig = Rig(DefaultStatePage { NSView() })
        _ = try #require(rig.pages.view(for: rig.key))
        rig.provider.keep = [.unsavedEdits]
        rig.show()
        rig.hide()
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "a page with unsaved edits lost its view")
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden)
        #expect(rig.discards.exemptions[rig.key] == .unsavedEdits)
        #expect(rig.discards.nextCheck == 600)
        #expect(rig.discards.hasDeadline)

        rig.provider.keep = []
        rig.advance(600)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) == nil)
    }

    @Test func oneOneShotDeadlineAndNoneForANeverPolicyOrAShownPage() throws {
        let rig = Rig(DefaultStatePage { NSView() })
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        #expect(!rig.discards.hasDeadline, "a shown page needs no deadline")
        rig.hide()
        #expect(rig.discards.hasDeadline)
        #expect(rig.discards.nextCheck == 600)
        rig.advance(120)
        rig.discards.replan()
        #expect(rig.discards.nextCheck == 480, "one deadline, at the policy's end")
        rig.show()
        #expect(!rig.discards.hasDeadline)
        #expect(rig.discards.nextCheck == nil)

        rig.provider.policy = .never
        rig.hide()
        #expect(!rig.discards.hasDeadline, "a never policy has no deadline")
    }

    @Test func aShowWhileThePageSavesItsStateKeepsItsView() async throws {
        let provider = ReportingPage { NSView() }
        let rig = Rig(provider)
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        // The tab shows again while its state is read: the lifecycle's generation moved.
        provider.onSave = { [rig] in rig.show() }
        rig.advance(601)
        rig.discards.replan()
        await rig.discards.settled()
        #expect(rig.pages.existingView(rig.key) != nil, "a late preparation let a shown page go")
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(rig.discards.discardedCount == 0)
    }

    @Test func withTheFeatureOffNothingIsDiscarded() throws {
        let rig = Rig(DefaultStatePage { NSView() })
        rig.pages.discards = nil
        _ = try #require(rig.pages.view(for: rig.key))
        rig.show()
        rig.hide()
        #expect(!rig.discards.hasDeadline)
        #expect(rig.pages.existingView(rig.key) != nil)
        #expect(InternalPageTabStore.discarding(rig.cache) == nil)
    }

    // MARK: Rig

    @MainActor final class Rig {
        let services: AppServices
        let provider: TestPage
        let discards = ContentDiscardScheduler(kind: .internalPage)
        let pane = Pane()
        let key: String
        var clock = ContinuousClock.now
        var cache: TabContentCache { services.cache }
        var pages: InternalPageTabStore { services.pages }

        init(_ provider: some TestPage & InternalPageProvider) {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            self.provider = provider
            services.pages.register(provider)
            discards.host = services.pages
            services.pages.cache = services.cache
            services.pages.discards = discards
            key = services.pages.open(provider.page, in: "pane-discard-test", of: DaemonStore())
            discards.now = { [weak self] in self?.clock ?? .now }
        }

        func show() { cache.present(key, by: pane, presence: .visible) }
        func hide() { cache.withdraw(key, by: pane) }
        func advance(_ seconds: Int64) { clock += .seconds(seconds) }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }

    /// What both test pages share; the subclasses differ only in the view state they keep.
    @MainActor class TestPage {
        let page = InternalPageID(rawValue: "discard-test")
        let title = "Discard test"
        let symbol = "doc"
        var policy = ContentDiscardPolicy.standard
        var keep: [CannotDiscardReason] = []
        var discarded: [String] = []
        var made = 0
        private let make: () -> NSView

        init(_ make: @escaping () -> NSView) {
            self.make = make
        }

        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return make()
        }

        func discardPolicy(for key: String) -> ContentDiscardPolicy { policy }
        func keepReasons(for key: String) -> [CannotDiscardReason] { keep }
        func viewDiscarded(_ key: String) { discarded.append(key) }
    }

    /// A page on the provider's default view state (its first scroll view's position).
    @MainActor final class DefaultStatePage: TestPage, InternalPageProvider {}

    /// A page that reports its own scroll, as a web page reads it from its document.
    @MainActor final class ReportingPage: TestPage, InternalPageProvider {
        var reportedScroll: CGPoint?
        var restored: [ContentViewState] = []
        /// Runs while the state is read (a show in the middle of a discard).
        var onSave: (() -> Void)?

        func saveViewState(for key: String, content: NSView) async -> ContentViewState {
            onSave?()
            return ContentViewState(scroll: reportedScroll)
        }

        func restoreViewState(_ state: ContentViewState, for key: String, content: NSView) {
            restored.append(state)
        }
    }

    private static func pageFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "page-discard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<html><body style='height:4000px'></body></html>".utf8).write(to: folder.appending(path: "index.html"))
        return folder
    }

    private static func scrollingContent() -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.hasVerticalScroller = true
        return scroll
    }

    private static func picture() -> CGImage? {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }
}
