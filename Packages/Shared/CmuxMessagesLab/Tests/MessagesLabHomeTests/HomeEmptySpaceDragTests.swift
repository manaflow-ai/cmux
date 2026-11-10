import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The floating Chief's own window moves from a press on the chat's empty space (user 2026-11-09: "it should be
/// raycast-type floating window", and the Chief's drags on empty space in the real chat must move it), and only
/// there: a press on a message (its text selects), a link, the message box or the header strip stays the chat's.
/// A real `ChatController` over a loaded conversation in an offscreen window.
@MainActor @Suite(.serialized) struct HomeEmptySpaceDragTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let link = "https://github.com/manaflow-ai/cmux/pull/1"

    private func controller() -> (NSWindow, ChatController) {
        _ = NSApplication.shared
        HomeMarkdownPolicy.install()
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: me, parts: [.text("Is the build green?")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
                     TranscriptItem(key: IdempotencyKey("k2"), seq: Seq(2), author: chief, parts: [.text("Yes: see [PR 1](\(Self.link)).")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_2"))]
        let summary = ConversationSummary(id: ConversationID("conv_drag"), title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_drag"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 620), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 440, height: 620)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return (window, controller)
    }

    /// The first point (scan order, host coordinates) where `test` holds.
    private func point(in controller: ChatController, where test: (CGPoint) -> Bool) -> CGPoint? {
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) where test(CGPoint(x: x, y: y)) { return CGPoint(x: x, y: y) }
        }
        return nil
    }

    @Test func onlyAPressOnTheChatsEmptySpaceMovesTheWindow() throws {
        let (window, controller) = controller()
        defer { window.close() }
        let demo = try #require(controller.demo)
        let bubble = try #require(point(in: controller) { demo.hit($0) != nil && controller.linkURL(at: $0) == nil }, "no message shows")
        #expect(!controller.isEmptySpace(at: bubble), "a press on a message (its text selects) would move the window")
        let link = try #require(point(in: controller) { controller.linkURL(at: $0)?.absoluteString == Self.link }, "no link shows")
        #expect(!controller.isEmptySpace(at: link), "a press on a link would move the window")
        let field = demo.compose.fieldRect
        #expect(!controller.isEmptySpace(at: CGPoint(x: field.midX, y: field.midY)), "a press in the message box would move the window")
        #expect(!controller.isEmptySpace(at: CGPoint(x: 20, y: max(1, controller.host.titlebarHeight - 2))), "a press on the header strip")
        let empty = try #require(point(in: controller) { p in
            p.y > controller.host.titlebarHeight + 4 && p.y < field.minY - 20 && demo.hit(p) == nil
        }, "no empty space between the header and the message box")
        #expect(controller.isEmptySpace(at: empty), "a press on empty space at \(empty) does not move the window")
        // What the window asks: the view a press there hits (the transcript's document view) and whether it moves.
        let windowPoint = controller.host.convert(empty, to: nil)
        let frameView = try #require(window.contentView?.superview)
        let hit = try #require(frameView.hitTest(frameView.convert(windowPoint, from: nil)))
        #expect(controller.pressMovesWindow(atWindowPoint: windowPoint, hit: hit) == true,
                "the press on empty space hits \(type(of: hit)), which does not say it moves the window")
        let onBubble = controller.host.convert(bubble, to: nil)
        let bubbleHit = try #require(frameView.hitTest(frameView.convert(onBubble, from: nil)))
        #expect(controller.pressMovesWindow(atWindowPoint: onBubble, hit: bubbleHit) == false, "a press on a message moves the window")
    }
}
