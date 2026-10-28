import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFeatures
import CmuxNextHibernation
@testable import CmuxNextHome
import CmuxNextWakeupsTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// Conversation tab discards (`memoryDiscardConversations`): a conversation tab hidden for 10
/// minutes, or 10 s at critical memory pressure, lets its transcript's laid-out rows, row cells, open thread view
/// and the bitmaps only they drew go (row cache 0), and keeps its view, messages, draft and scroll place. Its show
/// lays the rows out again once, at the view's first layout back in its pane (at the pane's size then), around the
/// row that was at the top, with every message that arrived meanwhile; the draft typed while it was released is in
/// the field. Rows that still move keep it until they rest.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ConversationDiscardTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_discard")

    /// The display frames an offscreen window never gets: the transcript's next-frame work runs when the test
    /// starts the next frame.
    final class Frames {
        var work: [() -> Void] = []
        func start() {
            let now = work
            work.removeAll()
            now.forEach { $0() }
        }
    }

    /// One conversation's transcript in an offscreen window's pane, `count` messages loaded. `salt` goes into every
    /// message's text, so its rows are drawn by no other test's transcript (the shared bitmap cache keeps rows another
    /// live view lays out).
    @MainActor final class Transcript {
        let frames: Frames
        let window: NSWindow
        /// The pane's content host: the conversation's view is in it while its tab shows.
        let pane: NSView
        let view: HomeNativeTranscriptView
        let store: MessagesLabHome.Store
        var core: ProjectionCore
        var items: [TranscriptItem]
        let summary: CmuxHomeCore.ConversationSummary
        let salt: String
        var layout: HomeTranscriptLayout { HomeTranscriptLayout(view) }
        var demo: MessagesWindowView {
            guard let demo = view.transcript.controller.demo else { fatalError("the transcript is installed in init") }
            return demo
        }

        init(count: Int = 160, width: CGFloat = 640, salt: String = String(UUID().uuidString.prefix(8))) {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let summary = CmuxHomeCore.ConversationSummary(id: ConversationDiscardTests.id, title: "Chief", participants: [
                CmuxHomeCore.Participant(id: ConversationDiscardTests.me, kind: .human, displayName: "Me"),
                CmuxHomeCore.Participant(id: ConversationDiscardTests.chief, kind: .agent, displayName: "Chief", agentClass: .chief),
            ], lastSeq: UInt64(count), createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
            let items = (1...count).map { Self.item($0, base: base, salt: salt) }
            let view = HomeNativeTranscriptView(store: HomeStore(source: MockHomeSource(options: .immediate)), conversation: ConversationDiscardTests.id,
                                                me: ConversationDiscardTests.me, deadlines: linklessDeadlines())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
            window.contentView = pane
            view.frame = pane.bounds
            pane.addSubview(view)
            var core = ProjectionCore(me: ConversationDiscardTests.me)
            let (conv, w) = core.install(ConversationDiscardTests.id, items: items, summary: summary)
            let frames = Frames()
            view.transcript.controller.nextFrame = { [frames] f in frames.work.append(f) }
            store = view.transcript.controller.install(conv, windowStart: w.start, total: w.total)
            self.items = items
            self.summary = summary
            self.salt = salt
            self.view = view
            self.window = window
            self.pane = pane
            self.core = core
            self.frames = frames
            pane.layoutSubtreeIfNeeded()
            frames.start()
        }

        static func item(_ seq: Int, base: Date, salt: String) -> TranscriptItem {
            let text = seq.isMultiple(of: 3) ? "Message \(seq) \(salt): a longer line that wraps across the bubble at this width, twice over to be sure."
                : "Message \(seq) \(salt)"
            return TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: UInt64(seq), author: seq.isMultiple(of: 2) ? ConversationDiscardTests.me : ConversationDiscardTests.chief,
                                  parts: [.text(text)], createdAt: base.addingTimeInterval(Double(seq)), delivery: .committed,
                                  messageID: MessageID("msg_\(seq)"))
        }

        /// The person scrolled `back` points up from the newest message.
        func scrollUp(_ back: CGFloat) {
            demo.collection.contentOffset = CGPoint(x: 0, y: demo.pinnedOffset - back)
            demo.userScrolled()
        }

        /// The Chief's next message arrives through the projection, as HomeStore's would.
        func receive() {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            items.append(Self.item(items.count + 1, base: base, salt: salt))
            let diff = core.step(items: items, summary: summary)
            for action in diff.actions { store.dispatch(action) }
        }

        /// The visible rows' indices.
        var visibleRows: Range<Int> {
            let y = demo.collection.contentOffset.y - demo.layout.rowsTop
            return demo.model.range(y, y + demo.cvHeight)
        }

        /// The pane shows another tab: the conversation's view leaves the window (`PaneContentView.retire`: a Home
        /// view is not parkable content) and keeps the size it had.
        func park() { view.removeFromSuperview() }

        /// The pane shows the tab again (`PaneContentView.install`): the view comes back at the pane's size, and the
        /// window lays it out before its next frame.
        func attach() {
            if view.superview !== pane { pane.addSubview(view) }
            view.frame = pane.bounds
            pane.layoutSubtreeIfNeeded()
        }

        /// The pane changed width (the window, a split or the sidebar divider).
        func resizePane(width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 700))
            pane.setFrameSize(NSSize(width: width, height: 700))
            if view.superview === pane { attach() }
        }

        /// The engine's wakes run its cleanup until every flight landed and every fade ended (`MessagesWindowView.settle`).
        func settleMotion() {
            for later in [2.0, 10, 60, 700, 1_400] { demo.settle(at: demo.clock() + later) }
            frames.start()
        }
    }

    /// One view's row layouts since it was made: restored layouts and width passes (a width pass derives every row).
    @MainActor struct Passes {
        let view: MessagesWindowView
        let restored: Int
        let width: Int
        init(_ view: MessagesWindowView) {
            self.view = view
            restored = view.restoredLayouts
            width = view.ownWidthPasses
        }
        var restoredSince: Int { view.restoredLayouts - restored }
        var widthSince: Int { view.ownWidthPasses - width }
    }

    @Test func aReleasedTranscriptComesBackOnItsRowOnceAtThePanesNewWidthWithEveryChange() throws {
        let rig = Transcript()
        defer { rig.window.close() }
        rig.scrollUp(1_800)
        let before = try #require(rig.demo.anchorProbe, "scrolled up, the transcript has a first visible row")
        let rowsBefore = rig.demo.model.count
        #expect(rig.layout.rowCacheCount > 0)
        #expect(rig.layout.isAtRest)

        rig.park()
        #expect(rig.layout.release())
        #expect(rig.layout.isReleased)
        #expect(rig.layout.rowCacheCount == 0, "rows or cells stayed after the release")
        #expect(rig.layout.release(), "a second release is a no-op that reports the rows gone")

        // While hidden: the person's draft (Send Message… from elsewhere), a new message, and a narrower pane.
        rig.view.showDraft("half a reply")
        rig.receive()
        rig.resizePane(width: 520)
        rig.frames.start()
        #expect(rig.layout.rowCacheCount == 0, "a change laid rows out while released")
        #expect(rig.view.transcript.draftText == "half a reply")
        #expect(rig.demo.compose.textView.view.string == "half a reply", "the field lost the draft typed while released")

        // The show: the lifecycle's restore runs first, the view still out of the window (PaneController.showSelected
        // presents before `view.show`), so it lays nothing out at the 640 pt it was hidden at.
        let passes = Passes(rig.demo)
        rig.layout.restore()
        rig.view.layoutSubtreeIfNeeded()
        #expect(rig.layout.isReleased, "the restore laid rows out before the view was back in its pane")
        #expect(rig.layout.rowCacheCount == 0)
        #expect(passes.restoredSince == 0)

        rig.attach()
        #expect(!rig.layout.isReleased)
        #expect(passes.restoredSince == 1, "the show laid the rows out \(passes.restoredSince) times")
        #expect(passes.widthSince == 0, "the show ran a width pass after the restore: every row derived twice")
        let after = try #require(rig.demo.anchorProbe)
        #expect(after.key == before.key, "the show came back on \(after.key), not \(before.key)")
        #expect(abs(after.y - before.y) <= 1, "the anchored row moved from \(before.y) to \(after.y)")
        #expect(rig.demo.model.count > rowsBefore, "the message that arrived while released is not in the rows")
        for i in rig.visibleRows {
            let spec = rig.demo.model.rows[i].spec
            #expect(spec.estimated == false, "visible row \(i) shows an estimate")
            if case .part = spec.kind { #expect(spec.width == 520, "visible row \(i) is laid out for \(spec.width) pt") }
        }
        #expect(rig.view.transcript.draftText == "half a reply")
    }

    @Test func aPinnedTranscriptComesBackPinnedWithTheNewestMessage() {
        let rig = Transcript()
        defer { rig.window.close() }
        #expect(rig.store.state.ui.scroll.pinnedToBottom)
        rig.park()
        #expect(rig.layout.release())
        rig.receive()
        rig.layout.restore()
        rig.attach()
        #expect(!rig.layout.isReleased)
        #expect(abs(rig.demo.collection.contentOffset.y - rig.demo.pinnedOffset) <= 1, "the show is not pinned to the newest message")
        let newest = "k\(rig.items.count)"
        #expect(rig.demo.model.rows.contains { RowBuilder.owner($0.spec.key).map(String.init) == newest },
                "the message that arrived while released has no row")
        let visible = rig.visibleRows
        #expect(!visible.isEmpty)
        for i in visible { #expect(rig.demo.model.rows[i].spec.estimated == false) }
    }

    @Test func theNearMessagesAreTheFortyAroundTheCenter() {
        let msgs = (0..<200).map { MessagesLabHome.Message(id: "m\($0)", senderId: "a", sentAt: "", parts: [], reactions: []) }
        #expect(MessagesWindowView.messages(around: nil, in: msgs) == 160..<200)
        #expect(MessagesWindowView.messages(around: "m100", in: msgs) == 80..<120)
        #expect(MessagesWindowView.messages(around: "m3", in: msgs) == 0..<40)
        #expect(MessagesWindowView.messages(around: "m199", in: msgs) == 160..<200)
        #expect(MessagesWindowView.messages(around: "gone", in: msgs) == 160..<200)
        #expect(MessagesWindowView.messages(around: "m1", in: Array(msgs.prefix(10))) == 0..<10)
    }

    // MARK: What goes with the rows (the shared caches: MessagesLabHomeTests/HomeReleasedRowsCacheTests)

    @Test func aReleasedThreadViewGoesWithTheRowsAndComesBackAsItWas() throws {
        let rig = Transcript()
        defer { rig.window.close() }
        let root = try #require(rig.store.state.conversation.messages.last?.id)
        rig.store.dispatch(MessagesLabHome.Action.openThread(path: [root]))
        rig.frames.start()
        rig.settleMotion()
        let keys = rig.demo.threadRowKeys
        try #require(!keys.isEmpty, "the thread view did not open")
        try #require(rig.layout.isAtRest)
        #expect(rig.layout.rowCacheCount >= rig.demo.model.count + keys.count, "the open thread view's rows are not counted")

        rig.park()
        #expect(rig.layout.release())
        #expect(rig.layout.rowCacheCount == 0, "the thread view's rows stayed")
        #expect(rig.demo.threadViews.isEmpty)
        #expect(rig.demo.threadHeaderFrame == nil)
        #expect(rig.store.state.ui.openThread != nil, "the release closed the person's thread")

        rig.layout.restore()
        rig.attach()
        #expect(rig.demo.threadRowKeys == keys, "the thread view came back with other rows")
        #expect(rig.demo.threadViews.count == keys.count)
        for v in rig.demo.threadViews {
            #expect(v.layer.animationKeys() == nil, "a restored thread row flew or faded in")
        }
    }

    // MARK: Through the content lifecycle

    @Test func aHiddenConversationTabPastTenMinutesIsDiscardedAndItsShowLaysItOutOnceAtThePanesWidth() async throws {
        let rig = TabRig()
        defer { rig.transcript.window.close() }
        rig.transcript.scrollUp(1_200)
        let before = try #require(rig.transcript.demo.anchorProbe)
        rig.show()
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        rig.hide()
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden)
        #expect(rig.scheduler.nextCheck == 600, "the conversation policy's 10 minutes")

        rig.advance(599)
        rig.scheduler.replan()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden, "discarded before its 10 minutes")
        #expect(rig.transcript.layout.rowCacheCount > 0)

        rig.advance(2)
        rig.scheduler.replan()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(rig.transcript.layout.rowCacheCount == 0, "the discarded conversation holds rows")
        #expect(rig.scheduler.discardedCount == 1)

        rig.transcript.view.showDraft("typed while gone")
        rig.transcript.resizePane(width: 560)
        let passes = Passes(rig.transcript.demo)
        rig.show()
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(rig.transcript.layout.rowCacheCount > 0)
        #expect(passes.restoredSince == 1)
        #expect(passes.widthSince == 0, "the show derived the rows again at the pane's width after the restore")
        let after = try #require(rig.transcript.demo.anchorProbe)
        #expect(after.key == before.key)
        #expect(abs(after.y - before.y) <= 1)
        for i in rig.transcript.visibleRows {
            let spec = rig.transcript.demo.model.rows[i].spec
            if case .part = spec.kind { #expect(spec.width == 560, "visible row \(i) is laid out for \(spec.width) pt") }
        }
        #expect(rig.transcript.view.transcript.draftText == "typed while gone")
    }

    @Test func aConversationWhoseRowsMoveKeepsThemUntilTheyRestThenGoes() async throws {
        let rig = TabRig()
        defer { rig.transcript.window.close() }
        rig.show()
        rig.transcript.store.dispatch(.setDraft("on its way"))
        rig.transcript.store.dispatch(.send)
        try #require(!rig.transcript.layout.isAtRest, "the send did not start its flight")
        rig.hide()

        rig.advance(601)
        rig.scheduler.replan()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden, "discarded while its send flew")
        #expect(rig.transcript.layout.rowCacheCount > 0)
        #expect(rig.scheduler.exemptions[rig.key] == .visible)
        #expect(rig.scheduler.nextCheck == ContentDiscardScheduler.drawnRecheck, "no look again once the motion ends")

        rig.transcript.settleMotion()
        try #require(rig.transcript.layout.isAtRest, "the flight never landed")
        rig.advance(1)
        rig.scheduler.replan()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(rig.transcript.layout.rowCacheCount == 0)
        #expect(rig.scheduler.exemptions[rig.key] == nil)
    }

    @Test func atCriticalPressureAHiddenConversationGoesAfterTenSeconds() async {
        let rig = TabRig()
        defer { rig.transcript.window.close() }
        rig.show()
        rig.hide()
        rig.scheduler.update(pressure: .critical)
        rig.advance(5)
        rig.scheduler.replan()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: rig.key) == .mountedHidden, "the last keystrokes' 10 s were not kept")
        rig.advance(6)
        rig.scheduler.replan()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(rig.transcript.layout.rowCacheCount == 0)
    }

    @Test func aShownConversationIsNeverDiscarded() async {
        let rig = TabRig()
        defer { rig.transcript.window.close() }
        rig.show()
        rig.scheduler.update(pressure: .critical)
        rig.advance(3_600)
        rig.scheduler.replan()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(rig.transcript.layout.rowCacheCount > 0)
        #expect(!rig.scheduler.hasDeadline)
    }

    @Test func thePageAndConversationOwnersEachTakeOnlyTheirOwnTabs() async throws {
        let page = InternalPageDiscardTests.DefaultStatePage { NSView() }
        let rig = TabRig(page: page)
        defer { rig.transcript.window.close() }
        let pageKey = try #require(rig.pageKey)
        let pageDiscards = try #require(rig.pageDiscards)
        _ = try #require(rig.services.pages.view(for: pageKey))
        rig.cache.present(pageKey, by: rig.pane, presence: .visible)
        rig.cache.withdraw(pageKey, by: rig.pane)
        rig.show()
        rig.hide()
        #expect(pageDiscards.nextCheck == 600)
        #expect(rig.scheduler.nextCheck == 600)

        rig.advance(601)
        pageDiscards.replan()
        rig.scheduler.replan()
        await pageDiscards.settled()
        await rig.scheduler.settled()
        #expect(rig.cache.phase(of: pageKey) == .hibernated)
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        #expect(page.discarded == [pageKey], "the page owner took another tab's discard")
        #expect(rig.services.pages.existingView(pageKey) == nil)
        #expect(rig.transcript.layout.rowCacheCount == 0)
        #expect(pageDiscards.discardedCount == 1)
        #expect(rig.scheduler.discardedCount == 1)

        // Each show's restore effect goes to its own owner.
        _ = try #require(rig.services.pages.view(for: pageKey))
        rig.cache.present(pageKey, by: rig.pane, presence: .visible)
        #expect(rig.cache.phase(of: pageKey) == .mountedVisible)
        #expect(page.made == 2)
        #expect(rig.transcript.layout.isReleased, "the page's show laid the conversation out")
        #expect(rig.cache.phase(of: rig.key) == .hibernated)
        rig.cache.withdraw(pageKey, by: rig.pane)
        rig.show()
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(!rig.transcript.layout.isReleased)
        #expect(rig.transcript.layout.rowCacheCount > 0)
        #expect(page.made == 2, "the conversation's show made a page view")
    }

    @Test func withTheFeatureOffNoConversationIsDiscarded() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(!services.features.isEnabled(.memoryDiscardConversations))
        #expect(services.cache.contentOwners.first(LayoutDiscardHost<ContentLifecycle<String>.Token>.self) == nil)
    }

    // MARK: Rig

    @MainActor final class TabRig {
        static let key = "conversation-discard-test"
        let services: AppServices
        let clock: ManualClock
        let scheduler: ContentDiscardScheduler
        let transcript: Transcript
        let pane = Pane()
        /// With a page provider: the page tab and its discards, wired first, as AppMemoryConsumers does.
        let pageKey: String?
        let pageDiscards: ContentDiscardScheduler?
        var key: String { Self.key }
        var cache: TabContentCache { services.cache }

        init(page: (any InternalPageProvider)? = nil) {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            let clock = ManualClock(), transcript = Transcript(), view = transcript.view
            if let page {
                let discards = ContentDiscardScheduler(kind: .internalPage, clock: clock)
                services.pages.register(page)
                services.pages.enableDiscards(discards, on: services.cache)
                pageKey = services.pages.open(page.page, in: "pane-conversation-discard-test", of: DaemonStore())
                pageDiscards = discards
            } else {
                pageKey = nil
                pageDiscards = nil
            }
            let scheduler = ContentDiscardScheduler(kind: .conversation, clock: clock)
            // What AppMemoryConsumers does with `memoryDiscardConversations` on, over this test's transcript.
            AppMemoryConsumers.conversationDiscards(scheduler, on: services.cache) { $0 == TabRig.key ? view : nil }
            self.services = services
            self.clock = clock
            self.scheduler = scheduler
            self.transcript = transcript
        }

        /// The pane shows the tab as `PaneController.showSelected` does: the content cache presents it (a discarded
        /// one gets its restore effect then), then the pane puts its view back and the window lays it out.
        func show() {
            cache.present(key, by: pane, presence: .visible)
            transcript.attach()
        }

        /// The pane shows another tab: the cache withdraws this one, and its view leaves the pane.
        func hide() {
            cache.withdraw(key, by: pane)
            transcript.park()
        }

        func advance(_ seconds: Int64) { clock.advance(by: .seconds(seconds)) }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}
