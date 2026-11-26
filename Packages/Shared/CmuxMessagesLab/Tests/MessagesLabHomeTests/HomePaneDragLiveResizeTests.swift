import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// A person's divider drag resizes Home's pane on every display frame, as a live window resize does, but Home only knew
/// the window's live resize (`inLiveResize`): in a divider drag the empty field's text view was resized, rewrapped and
/// laid out at every width (ComposeTextView.place and FieldTextView.setFrameSize, about 5% of Home's layout in the
/// sampled divider drags, release-resize bp-on-2 2026-11-26), and the transcript clip kept its mask. The host now hears
/// the pane's drag (`followPaneResize`) and takes the live-resize paths for it: the empty field keeps its text width
/// until the drag ends, while its glass follows every width.
@MainActor @Suite(.serialized) struct HomePaneDragLiveResizeTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// Home in an offscreen window at 900 pt with a short conversation and an empty draft.
    private func home() -> (NSWindow, NSView, MessagesLabHomeView) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: Self.them, parts: [.text("Started a99.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: Self.me, parts: [.text("Thanks.")],
                           createdAt: base.addingTimeInterval(1), delivery: .committed, messageID: MessageID("msg_2")),
        ]
        let id = ConversationID("conv_pane_drag")
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let view = MessagesLabHomeView(store: store, conversation: id, me: Self.me, wake: NoWake())
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.controller.install(conv, windowStart: w.start, total: w.total)
        container.layoutSubtreeIfNeeded()
        return (window, container, view)
    }

    private func resize(_ view: MessagesLabHomeView, in container: NSView, to width: CGFloat) {
        view.setFrameSize(NSSize(width: width, height: 700))
        container.layoutSubtreeIfNeeded()
    }

    @Test func aPaneDragKeepsTheEmptyFieldsTextWidthAndItsGlassFollows() throws {
        let (window, container, view) = home()
        defer { window.close() }
        let compose = try #require(view.controller.demo?.compose)
        let glass = view.controller.host.fieldChrome.field
        try #require(compose.textView.view.string.isEmpty, "fixture: the draft is not empty")
        let textWidth = compose.textView.clip.frame.width
        let glassWidth = glass.frame.width

        view.followPaneResize(true)
        var glassWidths: [CGFloat] = []
        for width in [880.0, 850, 820, 790] {
            resize(view, in: container, to: width)
            glassWidths.append(glass.frame.width)
            #expect(compose.textView.clip.frame.width == textWidth,
                    "at \(width) pt the empty field's text view took a new width in the drag (\(compose.textView.clip.frame.width) from \(textWidth))")
        }
        #expect(glassWidths.first.map { $0 < glassWidth } == true && glassWidths == glassWidths.sorted(by: >),
                "the field's glass did not follow the drag: \(glassWidths) from \(glassWidth)")

        view.followPaneResize(false)
        container.layoutSubtreeIfNeeded()
        let rested = compose.textView.clip.frame.width
        #expect(rested < textWidth, "the drag's end did not give the field its width (\(rested), was \(textWidth))")
        #expect(compose.textView.widthWaiting == nil, "a width still waits after the drag ended")
    }

    /// Outside a drag the field follows each width at once, as before.
    @Test func withoutADragTheFieldTakesEachWidth() throws {
        let (window, container, view) = home()
        defer { window.close() }
        let compose = try #require(view.controller.demo?.compose)
        let textWidth = compose.textView.clip.frame.width
        resize(view, in: container, to: 820)
        #expect(compose.textView.clip.frame.width < textWidth)
    }

    /// The drag's end comes once its layout landed; a window resize ending during a drag ends nothing (the drag still
    /// holds the width), and the drag's end then places it.
    @Test func aWindowLiveResizeEndingInsideAPaneDragKeepsTheDragsWidth() throws {
        let (window, container, view) = home()
        defer { window.close() }
        let compose = try #require(view.controller.demo?.compose)
        let textWidth = compose.textView.clip.frame.width
        view.followPaneResize(true)
        resize(view, in: container, to: 840)
        view.controller.host.viewWillStartLiveResize()
        view.controller.host.viewDidEndLiveResize()
        resize(view, in: container, to: 820)
        #expect(compose.textView.clip.frame.width == textWidth, "the window's resize end gave the field a width mid-drag")
        view.followPaneResize(false)
        container.layoutSubtreeIfNeeded()
        #expect(compose.textView.clip.frame.width < textWidth)
    }
}
