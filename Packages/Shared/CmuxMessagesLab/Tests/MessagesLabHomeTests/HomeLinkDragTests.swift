import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A link in a Home bubble drags out to make a split (Lawrence 2026-10-20: "I want to be able to
/// drag a link, like a PR URL, to the right side or anywhere and make a split"). A real
/// `ChatController` over a loaded conversation in an offscreen window: a press on a link that
/// moves past the slop hands the drag to the host (`onDragLink`) once, with the link's URL, and
/// makes no text selection; a press off any link still selects text and starts no link drag.
@MainActor @Suite(.serialized) struct HomeLinkDragTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let pr = "https://github.com/manaflow-ai/cmux/pull/22436"

    private func controller() -> (NSWindow, ChatController) {
        HomeMarkdownPolicy.install()
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief,
                                    parts: [.text("Plain words before the link, then [PR 22436](\(Self.pr)) after it and more plain words here.")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_1"))]
        let summary = ConversationSummary(id: ConversationID("conv_drag"), title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_drag"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return (window, controller)
    }

    /// The first point (scan order) where `match` holds for the link under it.
    private func point(in controller: ChatController, where match: (URL?) -> Bool) -> CGPoint? {
        let b = controller.host.bounds
        for y in stride(from: b.minY + 60, to: b.maxY - 80, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) {
                let p = CGPoint(x: x, y: y)
                guard controller.demo?.hit(p) != nil else { continue }
                if match(controller.linkURL(at: p)) { return p }
            }
        }
        return nil
    }

    private func event(_ type: NSEvent.EventType, _ p: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func aPressOnALinkThatMovesHandsTheDragToTheHost() throws {
        let (window, controller) = controller()
        var drags: [String] = []
        controller.onDragLink = { url, _ in drags.append(url.absoluteString); return true }
        let p = try #require(point(in: controller) { $0?.absoluteString == Self.pr })
        controller.mouseDown(at: p, event(.leftMouseDown, p, in: window))
        for dx in stride(from: 2.0, through: 40, by: 2) {
            let q = CGPoint(x: p.x + dx, y: p.y)
            controller.mouseDragged(at: q, event(.leftMouseDragged, q, in: window))
        }
        #expect(drags == [Self.pr])
        #expect(controller.selection.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func aPressOffAnyLinkStillSelectsText() throws {
        let (window, controller) = controller()
        var drags = 0
        controller.onDragLink = { _, _ in drags += 1; return true }
        let p = try #require(point(in: controller) { $0 == nil })
        controller.mouseDown(at: p, event(.leftMouseDown, p, in: window))
        for dx in stride(from: 2.0, through: 40, by: 2) {
            let q = CGPoint(x: p.x + dx, y: p.y)
            controller.mouseDragged(at: q, event(.leftMouseDragged, q, in: window))
        }
        #expect(drags == 0)
        withExtendedLifetime(window) {}
    }

    @Test func aDragTheHostRefusesSelectsTextAsBefore() throws {
        let (window, controller) = controller()
        var asked = 0
        controller.onDragLink = { _, _ in asked += 1; return false }
        let p = try #require(point(in: controller) { $0?.absoluteString == Self.pr })
        controller.mouseDown(at: p, event(.leftMouseDown, p, in: window))
        for dx in stride(from: 2.0, through: 40, by: 2) {
            let q = CGPoint(x: p.x + dx, y: p.y)
            controller.mouseDragged(at: q, event(.leftMouseDragged, q, in: window))
        }
        #expect(asked == 1)
        #expect(!controller.selection.isEmpty)
        withExtendedLifetime(window) {}
    }
}
