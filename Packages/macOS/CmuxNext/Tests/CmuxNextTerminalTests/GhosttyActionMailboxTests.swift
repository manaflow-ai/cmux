import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import GhosttyNextKit
import Testing

/// A surface's Ghostty state actions apply once per frame of its window, latest wins per slot; a discrete
/// action flushes what waits and runs after it, in order; an idle mailbox has no frame client
/// (p04-input-079). Drives a mailbox on a fake-link scheduler that ticks only when the test calls ``Rig/frame()``.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct GhosttyActionMailboxTests {
    /// A mailbox whose applies are recorded, on a scheduler of its own.
    final class Rig {
        let scheduler: FrameScheduler
        private(set) var applied: [String] = []
        private(set) var mailbox: GhosttyActionMailbox!
        private var frames = 0

        init() {
            let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
                MailboxTestLink()
            }
            self.scheduler = scheduler
            mailbox = GhosttyActionMailbox(owner: "terminal.actions", scheduler: { scheduler }) { [weak self] action in
                self?.applied.append(Self.label(action))
            }
        }

        /// One 120 Hz link frame.
        func frame() {
            frames += 1
            scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
        }

        /// `action` as the callback route sends it: a state action waits, a discrete one flushes and runs.
        func deliver(_ action: GhosttyAction) {
            if let slot = action.mailboxSlot { return mailbox.post(action, in: slot) }
            if action.flushesMailbox { mailbox.flush() }
            applied.append(Self.label(action))
        }

        var hasClient: Bool { scheduler.activeClients.contains("terminal.actions") }

        static func label(_ action: GhosttyAction) -> String {
            switch action {
            case .setTitle(let title): "title \(title)"
            case .pwd(let pwd): "pwd \(pwd)"
            case .scrollbar(let bar): "scrollbar \(bar.offsetRows)"
            case .mouseOverLink(let link): "link \(link ?? "-")"
            case .mouseShape: "shape"
            case .ringBell: "bell"
            case .commandFinished: "command"
            case .render: "render"
            default: "other"
            }
        }
    }

    static func bar(_ offset: UInt64) -> GhosttyAction {
        .scrollbar(TerminalScrollbar(totalRows: 1000, offsetRows: offset, visibleRows: 40))
    }

    @Test func fiftyStateActionsApplyOnceAtTheFrame() {
        let rig = Rig()
        for offset in 1...50 { rig.deliver(Self.bar(UInt64(offset))) }

        #expect(rig.applied.isEmpty, "a state action waits for the frame")
        #expect(rig.mailbox.pendingCount == 1)
        rig.frame()

        #expect(rig.applied == ["scrollbar 50"], "50 scrollbars are one apply of the latest")
        #expect(rig.mailbox.applies == 1)
        #expect(rig.mailbox.replaced == 49)
    }

    @Test func eachSlotKeepsItsLatestAndTheyApplyInTheOrderOfTheirLatest() {
        let rig = Rig()
        rig.deliver(.mouseOverLink("a"))
        rig.deliver(.mouseShape(GHOSTTY_MOUSE_SHAPE_POINTER))
        rig.deliver(.setTitle("one"))
        rig.deliver(.mouseOverLink("b"))
        rig.deliver(.setTitle("two"))
        rig.frame()

        #expect(rig.applied == ["shape", "link b", "title two"])
        #expect(rig.mailbox.applies == 1)
    }

    @Test func aDiscreteActionRunsAfterTheStateSentBeforeItInOrder() {
        let rig = Rig()
        rig.deliver(.setTitle("before"))
        rig.deliver(Self.bar(1))
        rig.deliver(.ringBell)
        rig.deliver(.setTitle("after"))
        rig.deliver(.commandFinished(TerminalCommandResult(exitCode: 0, duration: .seconds(1))))
        rig.deliver(Self.bar(2))

        #expect(rig.applied == ["title before", "scrollbar 1", "bell", "title after", "command"],
                "each discrete action sees the state Ghostty sent before it, at once")
        rig.frame()
        #expect(rig.applied.last == "scrollbar 2", "the state after the last discrete action waits for the frame")
        #expect(rig.mailbox.applies == 3)
    }

    @Test func aRedrawRequestDoesNotFlush() {
        let rig = Rig()
        rig.deliver(Self.bar(1))
        rig.deliver(.render)
        rig.deliver(Self.bar(2))

        #expect(rig.applied == ["render"], "a redraw reads no state: the scrollbar keeps waiting")
        rig.frame()
        #expect(rig.applied == ["render", "scrollbar 2"])
    }

    @Test func anEmptyMailboxHasNoFrameClient() {
        let rig = Rig()
        #expect(!rig.mailbox.isScheduled)
        #expect(!rig.hasClient, "no action yet: no client")

        rig.deliver(.setTitle("t"))
        #expect(rig.mailbox.isScheduled)
        #expect(rig.hasClient)

        rig.frame()
        #expect(!rig.mailbox.isScheduled, "the frame that applied it left the mailbox idle")
        #expect(!rig.hasClient)
        #expect(!rig.scheduler.hasActiveFrameClients)

        rig.frame()
        #expect(rig.applied == ["title t"], "an idle mailbox applies nothing more")
    }

    @Test func aFlushThatEmptiesTheMailboxDropsItsClientAtOnce() {
        let rig = Rig()
        rig.deliver(.pwd("/tmp"))
        #expect(rig.hasClient)

        rig.deliver(.ringBell)
        #expect(rig.applied == ["pwd /tmp", "bell"])
        #expect(!rig.mailbox.isScheduled, "nothing waits: no frame wake for it")
        #expect(!rig.hasClient)
    }

    @Test func anActionPostedWhileTheFrameAppliesWaitsForTheNextFrame() {
        var mailbox: GhosttyActionMailbox?
        var applied: [String] = []
        let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
            MailboxTestLink()
        }
        mailbox = GhosttyActionMailbox(owner: "terminal.actions", scheduler: { scheduler }) { action in
            applied.append(Rig.label(action))
            if case .setTitle("first") = action { mailbox?.post(.setTitle("second"), in: .title) }
        }
        mailbox?.post(.setTitle("first"), in: .title)
        scheduler.frameDidFire(timestamp: 1001, refreshInterval: 1.0 / 120)
        #expect(applied == ["title first"])
        #expect(mailbox?.isScheduled == true, "the title the apply posted keeps the client for the next frame")

        scheduler.frameDidFire(timestamp: 1002, refreshInterval: 1.0 / 120)
        #expect(applied == ["title first", "title second"])
        #expect(mailbox?.isScheduled == false)
    }

    @Test func everySlotHasItsActionAndDiscreteActionsHaveNone() {
        let state: [GhosttyAction] = [
            .setTitle("t"), .pwd("/"), .mouseShape(GHOSTTY_MOUSE_SHAPE_DEFAULT), .mouseVisible(false), .mouseOverLink(nil),
            .rendererHealthy(true), .progress(nil), .backgroundColor(red: 1, green: 2, blue: 3), Self.bar(0),
            .searchTotal(nil), .searchSelected(nil),
        ]
        #expect(state.compactMap(\.mailboxSlot) == GhosttyActionSlot.allCases)

        let discrete: [GhosttyAction] = [
            .host(.newWindow), .ringBell, .openURL("https://example.com"), .cellSize(width: 8, height: 16),
            .commandFinished(TerminalCommandResult(exitCode: nil, duration: .zero)), .childExited(exitCode: 0),
            .secureInput(GHOSTTY_SECURE_INPUT_ON), .readOnly(true), .keySequence(active: true),
            .reloadConfig(soft: false), .openConfig, .startSearch(""), .endSearch, .copyTitleToClipboard, .render,
        ]
        #expect(discrete.allSatisfy { $0.mailboxSlot == nil }, "events, requests and key-turn changes run at once")
        #expect(discrete.filter { !$0.flushesMailbox }.count == 1, "only a redraw request skips the flush")
    }
}

@MainActor
private final class MailboxTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
