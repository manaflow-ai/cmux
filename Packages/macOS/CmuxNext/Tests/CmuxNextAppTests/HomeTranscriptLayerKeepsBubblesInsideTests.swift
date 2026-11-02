import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabHome
import Testing

/// My blue bubbles stay inside the transcript when the layer above the chat
/// (`HomeNativeTranscriptView`) moves, narrows or resizes, with or without a
/// reply streaming (Lawrence 2026-10-19: "user bubbles clipped at right edge").
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeTranscriptLayerKeepsBubblesInsideTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_slide")
    static let turn = IdempotencyKey("turn_slide")
    static let long = "Fix all. Make sure that we have proper Sentry crash analytics set up so everything is observable to us. "
        + "Can you check Sentry CLI to see if there are any crashes there that you can fix?"

    /// The display frames an offscreen window never gets: the transcript's next-frame work
    /// (its width pass tick, the settled measure) runs when the test starts the next frame.
    final class Frames {
        var work: [() -> Void] = []
        func start() {
            let now = work
            work.removeAll()
            now.forEach { $0() }
        }
    }

    struct Rig {
        let frames: Frames
        let window: NSWindow
        let container: NSView
        let view: HomeNativeTranscriptView
        let store: Store
        var core: ProjectionCore
    }

    static var summary: ConversationSummary {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return ConversationSummary(id: id, title: "Chief", participants: [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
        ], lastSeq: 2, createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
    }

    /// Home's transcript layer in an offscreen window `width` wide, a long message of mine loaded.
    static func rig(width: CGFloat) -> Rig {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: chief, parts: [.text("Started a99.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: me, parts: [.text(long)],
                           createdAt: base.addingTimeInterval(1), delivery: .committed, messageID: MessageID("msg_2")),
        ]
        let home = HomeStore(source: MockHomeSource(options: .immediate))
        let view = HomeNativeTranscriptView(store: home, conversation: id, me: me)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let frames = Frames()
        view.transcript.controller.nextFrame = { [frames] f in frames.work.append(f) }
        let store = view.transcript.controller.install(conv, windowStart: w.start, total: w.total)
        container.layoutSubtreeIfNeeded()
        return Rig(frames: frames, window: window, container: container, view: view, store: store, core: core)
    }

    /// The Chief's reply streams one more chunk.
    static func stream(_ rig: inout Rig, _ text: String) {
        let rows = [HomeStreamRow(turn: turn, author: chief, text: text)]
        for action in rig.core.streams(rows, state: rig.store.state) { rig.store.dispatch(action) }
    }

    /// Every layer between the transcript frame and my rows has the transcript's width,
    /// and every row of mine was laid out for it and ends inside it. Inside the zoomed
    /// MessagesLabHomeView that width is in its own points: the frame over the chat's zoom.
    static func check(_ rig: Rig, width: CGFloat, _ step: String) {
        let lab = rig.view.transcript
        let inner = width / lab.zoom
        #expect(lab.frame.width == width, "\(step): MessagesLabHomeView \(lab.frame.width) pt in a \(width) pt transcript")
        #expect(lab.controller.host.frame.width == inner, "\(step): host \(lab.controller.host.frame.width) pt in \(inner) pt")
        guard let demo = lab.controller.demo else {
            Issue.record("\(step): no transcript")
            return
        }
        #expect(demo.bounds.width == inner, "\(step): demo \(demo.bounds.width) pt in \(inner) pt")
        #expect(demo.clip.frame.width == inner, "\(step): clip \(demo.clip.frame.width) pt in \(inner) pt")
        #expect(demo.clipMask.bounds.width == inner, "\(step): clip mask \(demo.clipMask.bounds.width) pt in \(inner) pt")
        #expect(demo.collection.frame.width == inner, "\(step): list \(demo.collection.frame.width) pt in \(inner) pt")
        for cell in demo.collection.visibleCells where !cell.isHidden {
            #expect(cell.frame.maxX <= inner + 0.5, "\(step): a row cell ends at \(cell.frame.maxX) pt, past \(inner) pt")
        }
        var mine = 0
        for row in demo.model.rows {
            guard case let .part(p) = row.spec.kind, p.outgoing else { continue }
            mine += 1
            #expect(row.spec.width == inner, "\(step): my row laid out for \(row.spec.width) pt in \(inner) pt")
            #expect(row.spec.metrics.rightEdge <= inner, "\(step): my bubble ends at \(row.spec.metrics.rightEdge) pt, past \(inner) pt")
        }
        #expect(mine > 0, "\(step): my message is not shown")
    }

    /// The layer above the chat: its frame moves (the window toolbar, a debug offset)
    /// or narrows (a pane width change) with or without a stream, at each width.
    @Test(arguments: [480.0, 620.0, 1200.0])
    func transcriptLayerChangesKeepMyBubblesInside(width: Double) {
        let w = CGFloat(width)
        var rig = Self.rig(width: w)
        defer { rig.window.close() }
        var chunk = "Working on it"
        for (i, change) in [(0.0, 40.0), (12.0, 0.0), (0.0, 0.0), (0.0, 120.0), (0.0, 0.0)].enumerated() {
            let (dx, trim) = (CGFloat(change.0), CGFloat(change.1))
            rig.frames.start()
            rig.view.debugTranscriptOffset = CGPoint(x: dx, y: 0)
            rig.view.debugTranscriptWidthTrim = trim
            if i % 2 == 0 {
                chunk += " more"
                Self.stream(&rig, chunk)
            }
            rig.container.layoutSubtreeIfNeeded()
            Self.check(rig, width: w - trim, "change \(i) dx \(dx) trim \(trim)")
        }
        // The layer itself resized with no layout request of its own (an autoresize).
        for next in [w * 0.6, w, w + 200] {
            rig.frames.start()
            rig.view.setFrameSize(NSSize(width: next, height: 700))
            chunk += " again"
            Self.stream(&rig, chunk)
            rig.container.layoutSubtreeIfNeeded()
            Self.check(rig, width: next, "resize to \(next)")
        }
    }
}
