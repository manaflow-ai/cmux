import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextFeatures
import CmuxNextHibernation
@testable import CmuxNextHome
import CmuxNextWakeupsTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// Conversation tab discards (`memoryDiscardConversations`, p07-memory-030): a conversation tab hidden for 10
/// minutes, or 10 s at critical memory pressure, lets its transcript's laid-out rows and row cells go (row cache
/// 0), and keeps its view, messages, draft and scroll place. Its show lays the rows out again around the row that
/// was at the top, at the view's current width, with every message that arrived meanwhile; the draft typed while
/// it was released is in the field.
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

    /// One conversation's transcript in an offscreen window, `count` messages loaded.
    @MainActor final class Transcript {
        let frames: Frames
        let window: NSWindow
        let view: HomeNativeTranscriptView
        let store: MessagesLabHome.Store
        var core: ProjectionCore
        var items: [TranscriptItem]
        let summary: CmuxHomeCore.ConversationSummary
        var layout: HomeTranscriptLayout { HomeTranscriptLayout(view) }
        var demo: MessagesWindowView {
            guard let demo = view.transcript.controller.demo else { fatalError("the transcript is installed in init") }
            return demo
        }

        init(count: Int = 160, width: CGFloat = 640) {
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let summary = CmuxHomeCore.ConversationSummary(id: ConversationDiscardTests.id, title: "Chief", participants: [
                CmuxHomeCore.Participant(id: ConversationDiscardTests.me, kind: .human, displayName: "Me"),
                CmuxHomeCore.Participant(id: ConversationDiscardTests.chief, kind: .agent, displayName: "Chief", agentClass: .chief),
            ], lastSeq: UInt64(count), createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
            let items = (1...count).map { Self.item($0, base: base) }
            let view = HomeNativeTranscriptView(store: HomeStore(source: MockHomeSource(options: .immediate)), conversation: ConversationDiscardTests.id,
                                                me: ConversationDiscardTests.me)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
            window.contentView = container
            view.frame = container.bounds
            container.addSubview(view)
            var core = ProjectionCore(me: ConversationDiscardTests.me)
            let (conv, w) = core.install(ConversationDiscardTests.id, items: items, summary: summary)
            let frames = Frames()
            view.transcript.controller.nextFrame = { [frames] f in frames.work.append(f) }
            store = view.transcript.controller.install(conv, windowStart: w.start, total: w.total)
            self.items = items
            self.summary = summary
            self.view = view
            self.window = window
            self.core = core
            self.frames = frames
            container.layoutSubtreeIfNeeded()
            frames.start()
        }

        static func item(_ seq: Int, base: Date) -> TranscriptItem {
            let text = seq.isMultiple(of: 3) ? "Message \(seq): a longer line that wraps across the bubble at this width, twice over to be sure."
                : "Message \(seq)"
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
            items.append(Self.item(items.count + 1, base: base))
            let diff = core.step(items: items, summary: summary)
            for action in diff.actions { store.dispatch(action) }
        }

        /// The visible rows' indices.
        var visibleRows: Range<Int> {
            let y = demo.collection.contentOffset.y - demo.layout.rowsTop
            return demo.model.range(y, y + demo.cvHeight)
        }

        func resize(width: CGFloat) {
            view.setFrameSize(NSSize(width: width, height: 700))
            view.superview?.layoutSubtreeIfNeeded()
        }
    }

    @Test func aReleasedTranscriptHoldsNoRowsAndComesBackOnItsRowWithEveryChange() throws {
        let rig = Transcript()
        defer { rig.window.close() }
        rig.scrollUp(1_800)
        let before = try #require(rig.demo.anchorProbe, "scrolled up, the transcript has a first visible row")
        let rowsBefore = rig.demo.model.count
        #expect(rig.layout.rowCacheCount > 0)
        #expect(rig.layout.isAtRest)

        #expect(rig.layout.release())
        #expect(rig.layout.isReleased)
        #expect(rig.layout.rowCacheCount == 0, "rows or cells stayed after the release")
        #expect(rig.layout.release(), "a second release is a no-op that reports the rows gone")

        // While hidden: the person's draft (Send Message… from elsewhere), a new message, and a pane resize.
        rig.view.showDraft("half a reply")
        rig.receive()
        rig.resize(width: 520)
        rig.frames.start()
        #expect(rig.layout.rowCacheCount == 0, "a change or a resize laid rows out while released")
        #expect(rig.view.transcript.draftText == "half a reply")
        #expect(rig.demo.compose.textView.view.string == "half a reply", "the field lost the draft typed while released")

        rig.layout.restore()
        #expect(!rig.layout.isReleased)
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
        #expect(rig.layout.release())
        rig.receive()
        rig.layout.restore()
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

    // MARK: Through the content lifecycle

    @Test func aHiddenConversationTabPastTenMinutesIsDiscardedAndItsShowLaysItOutAgain() async throws {
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
        rig.show()
        #expect(rig.cache.phase(of: rig.key) == .mountedVisible)
        #expect(rig.transcript.layout.rowCacheCount > 0)
        let after = try #require(rig.transcript.demo.anchorProbe)
        #expect(after.key == before.key)
        #expect(abs(after.y - before.y) <= 1)
        #expect(rig.transcript.view.transcript.draftText == "typed while gone")
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
        var key: String { Self.key }
        var cache: TabContentCache { services.cache }

        init() {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            let clock = ManualClock(), transcript = Transcript(), view = transcript.view
            let scheduler = ContentDiscardScheduler(kind: .conversation, clock: clock)
            // What AppMemoryConsumers does with `memoryDiscardConversations` on, over this test's transcript.
            AppMemoryConsumers.conversationDiscards(scheduler, on: services.cache) { $0 == TabRig.key ? view : nil }
            self.services = services
            self.clock = clock
            self.scheduler = scheduler
            self.transcript = transcript
        }

        /// The pane shows the tab: the view is drawn, then presented.
        func show() {
            transcript.view.isHidden = false
            cache.present(key, by: pane, presence: .visible)
        }

        /// The pane shows another tab: the view is parked hidden.
        func hide() {
            transcript.view.isHidden = true
            cache.withdraw(key, by: pane)
        }

        func advance(_ seconds: Int64) { clock.advance(by: .seconds(seconds)) }
    }

    @MainActor final class Pane: SurfacePresenter {
        func surfaceWasDisplaced(_ key: String) {}
    }
}
