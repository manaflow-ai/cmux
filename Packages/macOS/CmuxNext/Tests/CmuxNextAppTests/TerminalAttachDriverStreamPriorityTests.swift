import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Stream visibility priority: a view's link gets `set-stream-priority` from what the person sees.
/// It opens at its visibility, follows hide and show (TabContentCache's conceal and reveal), is focused while it
/// holds the app's one ``TerminalStreamFocus``, and a reattached link gets the current priority. Without the
/// feature (no stream focus) no link is ranked.
@Suite(.timeLimit(.minutes(1))) struct TerminalAttachDriverStreamPriorityTests {
    @Test func aLinkFollowsVisibilityAndFocus() async {
        let focus = TerminalStreamFocus()
        let link = RankLink()
        let driver = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in link },
                                                    streamFocus: focus)
        defer { driver.close() }
        driver.start()
        await Self.pump(link, on: driver)
        #expect(link.priorities == [.visible])

        driver.setVisible(false)
        #expect(link.priorities.last == .hidden)
        driver.setVisible(true)
        #expect(link.priorities.last == .visible)
        driver.takeStreamFocus()
        #expect(link.priorities.last == .focused)
        // Hidden while focused: hidden wins, and showing it again makes it focused.
        driver.setVisible(false)
        #expect(link.priorities.last == .hidden)
        driver.setVisible(true)
        #expect(link.priorities.last == .focused)
        #expect(link.priorities == [.visible, .hidden, .visible, .focused, .hidden, .focused])
    }

    @Test func focusingAnotherViewDemotesTheFirst() async {
        let focus = TerminalStreamFocus()
        let (first, second) = (RankLink(), RankLink())
        let one = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in first },
                                                 streamFocus: focus)
        let two = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in second },
                                                 streamFocus: focus)
        defer {
            one.close()
            two.close()
        }
        one.start()
        two.start()
        await Self.pump(first, on: one)
        await Self.pump(second, on: two)
        one.takeStreamFocus()
        #expect(first.priorities.last == .focused)
        two.takeStreamFocus()
        #expect(second.priorities.last == .focused)
        #expect(first.priorities.last == .visible)
        #expect(one.streamPriority == .visible)
        // Focusing the holder again sends nothing new.
        two.takeStreamFocus()
        #expect(second.priorities == [.visible, .focused])
    }

    /// Red before the fix (focus taken on each view's own input queue, its flag set after the take): two views
    /// taking focus at once could both end focused. Each round both take it from two threads; after it exactly
    /// one view is focused, and it is the holder.
    @Test func concurrentTakesLeaveExactlyTheHolderFocused() async {
        let focus = TerminalStreamFocus()
        let (first, second) = (RankLink(), RankLink())
        let one = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in first },
                                                 streamFocus: focus)
        let two = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in second },
                                                 streamFocus: focus)
        defer {
            one.close()
            two.close()
        }
        one.start()
        two.start()
        await Self.pump(first, on: one)
        await Self.pump(second, on: two)
        for _ in 0..<500 {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { one.takeStreamFocus() }
                group.addTask { two.takeStreamFocus() }
            }
            let holder = focus.holderView
            let (focusedOne, focusedTwo) = (one.streamPriority == .focused, two.streamPriority == .focused)
            #expect(focusedOne != focusedTwo)
            #expect(holder == (focusedOne ? ObjectIdentifier(one) : ObjectIdentifier(two)))
            #expect(first.priorities.last == one.streamPriority)
            #expect(second.priorities.last == two.streamPriority)
            guard focusedOne != focusedTwo else { return }
        }
    }

    /// Focus in a view's ordered input (geometry, reconnect) does not rank its stream: only the main thread's
    /// take does (`DaemonTerminalIO.streamFocusGained`), so a late input drain never takes the lane back.
    @Test func theOrderedFocusEventDoesNotTakeStreamFocus() async {
        let focus = TerminalStreamFocus()
        let link = RankLink()
        let driver = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in link },
                                                    streamFocus: focus)
        defer { driver.close() }
        driver.start()
        await Self.pump(link, on: driver)
        driver.focused()
        #expect(focus.holderView == nil)
        #expect(link.priorities == [.visible])
    }

    @Test func aHiddenViewOpensHiddenAndAReattachGetsTheCurrentPriority() async {
        let focus = TerminalStreamFocus()
        let (opened, report) = AsyncStream<RankLink>.makeStream()
        let driver = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), visible: false,
                                                    opener: { _ in
                                                        let link = RankLink()
                                                        report.yield(link)
                                                        return link
                                                    },
                                                    streamFocus: focus)
        defer { driver.close() }
        var links = opened.makeAsyncIterator()
        driver.start()
        guard let first = await links.next() else {
            Issue.record("no link opened")
            return
        }
        await Self.pump(first, on: driver)
        #expect(first.priorities == [.hidden])
        driver.setVisible(true)
        driver.takeStreamFocus()
        first.feed.yield(.closed(.overflow))
        guard let second = await links.next() else {
            Issue.record("no reattach")
            return
        }
        await Self.pump(second, on: driver)
        #expect(second.priorities == [.focused])
    }

    @Test func withoutTheFeatureNoLinkIsRanked() async {
        let link = RankLink()
        let driver = TerminalAttachDriver<RankLink>(initialSize: CellSize(cols: 80, rows: 24), opener: { _ in link })
        defer { driver.close() }
        driver.start()
        await Self.pump(link, on: driver)
        driver.setVisible(false)
        driver.takeStreamFocus()
        driver.setVisible(true)
        #expect(link.priorities.isEmpty)
    }

    @Test func aDroppedHolderIsNotDemotedLater() {
        let focus = TerminalStreamFocus()
        let demoted = Demoted()
        let view = ObjectIdentifier(Demoted.self)
        focus.take(view) { demoted.count() }
        focus.release(view)
        #expect(focus.holderView == nil)
        focus.take(ObjectIdentifier(RankLink.self)) {}
        #expect(demoted.value == 0)
    }

    /// Plays a replay on `link` and waits for its step: the driver pumps the link from then on.
    private static func pump(_ link: RankLink, on driver: TerminalAttachDriver<RankLink>) async {
        link.feed.yield(.replay(TerminalReplay(cols: 80, rows: 24, data: Data())))
        while let step = await driver.nextStep() {
            if case .replay = step { return }
        }
    }
}

/// A link that records each stream priority the driver sends; `feed` plays its stream.
nonisolated private final class RankLink: TerminalAttachLink {
    let events: AsyncStream<TerminalChannelEvent>
    let feed: AsyncStream<TerminalChannelEvent>.Continuation
    private let sent = Mutex<[TerminalStreamPriority]>([])

    init() {
        (events, feed) = AsyncStream<TerminalChannelEvent>.makeStream()
    }

    var priorities: [TerminalStreamPriority] { sent.withLock { $0 } }

    func sendInput(_ data: Data, keyFlow: UInt64) {}
    func sendClaim(reporting size: CellSize) {}
    func sendTakeOver(reporting size: CellSize, setLatest: Bool) {}
    func sendHidden(_ hidden: Bool) {}
    func sendSnapshotRequest(reason: SnapshotRequestReason) {}
    func setOutputSink(_ sink: TerminalEchoSink?) {}
    func sendStreamPriority(_ priority: TerminalStreamPriority) { sent.withLock { $0.append(priority) } }
    func detachNow() { feed.finish() }
}

/// How many times a holder was demoted.
nonisolated private final class Demoted: Sendable {
    private let demotions = Mutex(0)
    func count() { demotions.withLock { $0 += 1 } }
    var value: Int { demotions.withLock { $0 } }
}
