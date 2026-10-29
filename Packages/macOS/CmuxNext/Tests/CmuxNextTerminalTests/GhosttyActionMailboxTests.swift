import AppKit
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import GhosttyNextKit
import Testing

/// A surface's Ghostty state actions apply once per frame of its window, latest wins per slot; a discrete
/// action, a clipboard request and a close flush what waits and run after it, in order; an idle mailbox has
/// no frame client. Drives a real ``SurfaceBridge`` (its ``SurfaceBridge/deliver(_:runtime:)``
/// and Ghostty's clipboard and close callbacks) whose target records what reaches it, on a fake-link
/// scheduler that ticks only when the test calls ``Rig/frame()``.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct GhosttyActionMailboxTests {
    /// The surface's view to the bridge: records each call, in order.
    @MainActor final class Recorder: GhosttySurfaceTarget {
        let actionFrameScheduler: FrameScheduler
        private(set) var applied: [String] = []

        init(scheduler: FrameScheduler) {
            actionFrameScheduler = scheduler
        }

        func applyAction(_ action: GhosttyAction) -> Bool {
            applied.append(Rig.label(action))
            return true
        }

        func handleHostAction(_ action: TerminalHostAction) -> Bool {
            applied.append("host")
            return true
        }

        func confirmClipboard(contents: String, contentBytes: Int, kind: TerminalClipboardRequestKind, state: UncheckedPointer) {
            applied.append("confirm")
        }

        func writeClipboard(items: [TerminalClipboardItem], location: TerminalPasteboardLocation, requiresConfirmation: Bool) {
            applied.append("write \(items.map(\.text).joined())")
        }

        func surfaceRequestedClose() {
            applied.append("close")
        }
    }

    /// A surface bridge whose target records, on a scheduler of its own.
    @MainActor final class Rig {
        let scheduler: FrameScheduler
        let recorder: Recorder
        let bridge: SurfaceBridge
        private var frames = 0

        init() {
            let scheduler = FrameScheduler.testing(clock: ManualClock(), ledger: WakeupLedger(), mediaTime: { 1000 }) { _ in
                MailboxTestLink()
            }
            self.scheduler = scheduler
            recorder = Recorder(scheduler: scheduler)
            // The surface's input goes nowhere: these tests read only its actions.
            let lane = TerminalInputLane(drain: TerminalInputDrain(queue: DispatchQueue(label: "GhosttyActionMailboxTests.input", qos: .utility)) { _, _ in .next })
            bridge = SurfaceBridge(input: TerminalInputSink(lane: lane, typingSurface: TypingLatencyProbe(path: nil).makeSurfaceKey()))
            bridge.target = recorder
        }

        var mailbox: GhosttyActionMailbox { bridge.actionMailbox }
        var applied: [String] { recorder.applied }

        /// One 120 Hz link frame.
        func frame() {
            frames += 1
            scheduler.frameDidFire(timestamp: 1000 + Double(frames) / 120, refreshInterval: 1.0 / 120)
        }

        /// `action` through the bridge, as Ghostty's `action_cb` hands it over.
        @discardableResult
        func deliver(_ action: GhosttyAction) -> Bool {
            bridge.deliver(action, runtime: nil)
        }

        /// The bridge as Ghostty's surface callbacks pass it (`userdata`).
        var userdata: UnsafeMutableRawPointer {
            // SAFETY: the rig keeps the bridge alive for the test that passes this pointer.
            unsafe Unmanaged.passUnretained(bridge).toOpaque()
        }

        var hasClient: Bool { scheduler.activeClients.contains("terminal.actions") }

        static func label(_ action: GhosttyAction) -> String {
            switch action {
            case .setTitle(let title): "title \(title)"
            case .pwd(let pwd): "pwd \(pwd)"
            case .scrollbar(let bar): "scrollbar \(bar.offsetRows)"
            case .progress: "progress"
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
        for offset in 1...50 { #expect(rig.deliver(Self.bar(UInt64(offset))), "a waiting state action reports performed") }

        #expect(rig.applied.isEmpty, "a state action waits for the frame")
        #expect(rig.mailbox.pendingCount == 1)
        rig.frame()

        #expect(rig.applied == ["scrollbar 50"], "50 scrollbars are one apply of the latest")
        #expect(rig.mailbox.applies == 1)
        #expect(rig.mailbox.replaced == 49)
    }

    @Test func eachSlotKeepsItsLatestAndTheyApplyInTheOrderOfTheirLatest() {
        let rig = Rig()
        rig.deliver(.pwd("/a"))
        rig.deliver(.progress(nil))
        rig.deliver(.setTitle("one"))
        rig.deliver(.pwd("/b"))
        rig.deliver(.setTitle("two"))
        rig.frame()

        #expect(rig.applied == ["progress", "pwd /b", "title two"])
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

    /// Ghostty reports the link and pointer shape under the pointer inside the move
    /// (`ghostty_surface_mouse_pos`); the press, Cmd-click and link menu that follow in the same turn read them.
    @Test func theLinkAndPointerShapeUnderThePointerApplyInTheMovesTurn() {
        let rig = Rig()
        rig.deliver(.setTitle("t"))
        #expect(rig.deliver(.mouseOverLink("https://example.com")))
        #expect(rig.applied == ["title t", "link https://example.com"],
                "the link waited for the frame, or ran before the state sent before it")
        rig.deliver(.mouseShape(GHOSTTY_MOUSE_SHAPE_POINTER))
        rig.deliver(.mouseOverLink(nil))
        #expect(rig.applied == ["title t", "link https://example.com", "shape", "link -"])
        #expect(rig.mailbox.pendingCount == 0)
    }

    @Test func aHostActionRunsAfterTheStateSentBeforeIt() {
        let rig = Rig()
        rig.deliver(.setTitle("t"))
        #expect(rig.deliver(.host(.newWindow)))
        #expect(rig.applied == ["title t", "host"])
    }

    @Test func aClipboardWriteRunsAfterTheStateSentBeforeIt() {
        let rig = Rig()
        rig.deliver(.setTitle("before"))
        rig.deliver(Self.bar(1))
        let mime = "text/plain"
        let text = "copied"
        // SAFETY: the C strings and the item live for the callback, which copies what it keeps.
        unsafe mime.withCString { mime in
            // SAFETY: as above.
            unsafe text.withCString { data in
                // SAFETY: as above.
                var item = unsafe ghostty_clipboard_content_s(mime: mime, data: data, len: text.utf8.count)
                // SAFETY: as above.
                unsafe withUnsafePointer(to: &item) { item in
                    // SAFETY: as above; `userdata` is the rig's live bridge.
                    unsafe ghosttyWriteClipboard(rig.userdata, GHOSTTY_CLIPBOARD_SELECTION, item, 1, false)
                }
            }
        }

        #expect(rig.applied == ["title before", "scrollbar 1", "write copied"])
        #expect(rig.mailbox.pendingCount == 0)
        #expect(!rig.hasClient, "nothing waits after the write: no frame wake for it")
    }

    @Test func aClipboardConfirmRunsAfterTheStateSentBeforeIt() {
        let rig = Rig()
        rig.deliver(.pwd("/tmp"))
        // SAFETY: `userdata` is the rig's live bridge; no confirmation contents and no request state.
        unsafe ghosttyConfirmReadClipboard(rig.userdata, nil, nil, GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE)

        #expect(rig.applied == ["pwd /tmp", "confirm"])
        #expect(rig.mailbox.pendingCount == 0)
    }

    @Test func aCloseRunsOnALaterPassAfterTheStateSentBeforeIt() {
        let rig = Rig()
        rig.deliver(.setTitle("last"))
        // SAFETY: `userdata` is the rig's live bridge.
        unsafe ghosttyCloseSurface(rig.userdata, false)
        #expect(rig.applied.isEmpty, "a close never runs inside Ghostty's callback")

        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
        #expect(rig.applied == ["title last", "close"])
        #expect(rig.mailbox.pendingCount == 0)
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
            .setTitle("t"), .pwd("/"), .mouseVisible(false), .rendererHealthy(true), .progress(nil),
            .backgroundColor(red: 1, green: 2, blue: 3), Self.bar(0), .searchTotal(nil), .searchSelected(nil),
        ]
        #expect(state.compactMap(\.mailboxSlot) == GhosttyActionSlot.allCases)

        let discrete: [GhosttyAction] = [
            .host(.newWindow), .ringBell, .openURL("https://example.com"), .mouseShape(GHOSTTY_MOUSE_SHAPE_DEFAULT),
            .mouseOverLink(nil), .cellSize(width: 8, height: 16),
            .commandFinished(TerminalCommandResult(exitCode: nil, duration: .zero)), .childExited(exitCode: 0),
            .secureInput(GHOSTTY_SECURE_INPUT_ON), .readOnly(true), .keySequence(active: true),
            .reloadConfig(soft: false), .openConfig, .startSearch(""), .endSearch, .copyTitleToClipboard, .render,
        ]
        #expect(discrete.allSatisfy { $0.mailboxSlot == nil }, "events, requests and input-turn changes run at once")
        #expect(discrete.filter { !$0.flushesMailbox }.count == 1, "only a redraw request skips the flush")
    }
}

@MainActor
private final class MailboxTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
