#if os(iOS) && DEBUG
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// A disclosure in the transcript (here a tool call's output) opens and closes the way ChatGPT's
/// does: the tapped line stays where it is drawn while the body grows down from under it and
/// shrinks back, the transcript never re-pins to its newest row during the change, and with Reduce
/// Motion the row takes its new height at once. The transcript is a collection view of reused rows:
/// the tapped row's height moves on the disclosure's spring in the layout, so each check samples the
/// row's drawn frame every frame of the change, not only where it lands.
@MainActor
@Suite(.serialized) struct DisclosureFoldTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// Turns of a prompt, one read tool call with twelve lines of output (a native line at rest,
    /// its output a SwiftUI code card when open) and a short answer.
    static func events(turns: Int) -> [AgentSessionEvent] {
        (0 ..< turns).flatMap { n -> [AgentSessionEvent] in
            [
                .userMessage(text: "prompt \(n)", promptId: "p\(n)", turnId: "t\(n)", attachments: [], at: at),
                .turnStarted(turnId: "t\(n)", at: at),
                .update(.toolCall(ACPToolCall(id: "c\(n)", title: "Read a\(n).swift", kind: .read, status: .completed,
                                              content: [.content(.text((0 ..< 12).map { "let line\($0) = \(n)" }.joined(separator: "\n")))],
                                              locations: [.init(path: "Sources/a\(n).swift")]))),
                .update(.agentMessageChunk(text: "Answer \(n): the dialer retries with backoff.", messageId: "m\(n)")),
                .turnResult(turnId: "t\(n)", status: .completed, errorText: nil, at: at),
            ]
        }
    }

    @MainActor
    struct Chat {
        let controller: ChatTranscriptController
        let surface: AgentChatSurface
        let scroll: UICollectionView
        let window: UIWindow
        var list: ChatTranscriptList { controller.transcriptList }

        /// Row `id`'s cell top in the scroll view's own frame (where it is drawn on screen), and
        /// its height.
        func line(_ id: String) -> (y: CGFloat, height: CGFloat)? {
            guard let cell = list.cell(for: id) else { return nil }
            let frame = cell.layer.presentation()?.frame ?? cell.frame
            let offset = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
            return (frame.minY - offset, frame.height)
        }

        /// One display frame or so.
        func frame() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
            controller.view.layoutIfNeeded()
            CATransaction.flush()
        }
    }

    func chat(reducesMotion: Bool) throws -> Chat {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch(Self.events(turns: 30)))
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(placement: .owned, surface: surface, store: store,
                                                  empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil)
        controller.reducesMotion = { reducesMotion }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(JumpReduceMotionTests.collection(in: controller.view))
        for _ in 0 ..< 100 where scroll.contentSize.height < scroll.bounds.height * 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.layoutIfNeeded()
        }
        try #require(scroll.contentSize.height >= scroll.bounds.height * 4, "content measured \(scroll.contentSize.height)")
        // Rows near the reader are measured on later turns of the run loop.
        for _ in 0 ..< 10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.layoutIfNeeded()
        }
        return Chat(controller: controller, surface: surface, scroll: scroll, window: window)
    }

    /// Up in the middle of the transcript, no longer following the newest row.
    func readMiddle(_ chat: Chat) {
        chat.controller.scrollTranscript(toContentY: chat.scroll.contentSize.height / 2, animated: false)
        for _ in 0 ..< 10 { chat.frame() }
    }

    /// The tool row whose line is nearest the middle of the screen.
    func toolRow(_ chat: Chat) throws -> (id: String, key: String) {
        let middle = chat.scroll.contentOffset.y + chat.scroll.bounds.height / 2
        return try #require(chat.list.demoDisclosure(nearContentY: middle), "a tool row on screen")
    }

    /// What one disclosure change did, frame by frame until the hold let go.
    struct Change {
        var ys: [CGFloat] = []
        var heights: [CGFloat] = []
        var followed = false
        var folded = false
        var released = false
    }

    func watch(_ chat: Chat, _ id: String, frames: Int = 150) -> Change {
        var change = Change()
        for _ in 0 ..< frames {
            chat.frame()
            if let line = chat.line(id) {
                change.ys.append(line.y)
                change.heights.append(line.height)
            }
            change.followed = change.followed || chat.surface.following
            change.folded = change.folded || chat.list.isFolding
            if !chat.controller.isHoldingFold, chat.list.heldRow == nil, !chat.list.isFolding {
                change.released = true
                break
            }
        }
        return change
    }

    /// One tap's change as Reduce Motion plays it (`toggleDisclosure`'s Reduce Motion branch:
    /// no animation, the hold let go on the next turn of the main loop). The test runs on the
    /// main queue, which a spun run loop does not drain, so that next turn is one frame here.
    func toggleWithoutMotion(_ chat: Chat, row id: String, key: String, open: Bool) {
        let hold = chat.list.context.foldHold(id)
        let disclosures = chat.surface.disclosures
        hold.begin()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { disclosures.set(key, open) }
        chat.frame()
        hold.end()
    }

    @Test func theTappedLineStaysPutWhileItsBodyOpensAndCloses() throws {
        let chat = try chat(reducesMotion: false)
        defer { chat.window.isHidden = true }
        readMiddle(chat)
        #expect(!chat.surface.following)
        let row = try toolRow(chat)
        let before = try #require(chat.line(row.id))

        // Open, as its native line's tap does.
        chat.list.context.toggleFold(row: row.id, key: row.key, open: true)
        let opening = watch(chat, row.id)
        let opened = try #require(chat.line(row.id))
        #expect(opening.released, "the hold lets go once the animation completes")
        #expect(opening.ys.allSatisfy { abs($0 - before.y) <= 1 }, "the line moved while opening: from \(before.y) through \(opening.ys)")
        #expect(abs(opened.y - before.y) <= 1)
        #expect(opened.height > before.height + 100, "the output shows: \(before.height) -> \(opened.height)")
        #expect(opening.folded, "the row's height moved on the disclosure's spring")
        #expect(Set(opening.heights.map { Int($0) }).count > 3, "it passed through heights between: \(opening.heights)")
        #expect(!opening.followed, "the transcript never followed its newest row during the open")
        #expect(!chat.surface.following, "a reader up in the middle stays there")

        // Close, as its SwiftUI row's button does.
        chat.list.context.toggleFold(row: row.id, key: row.key, open: false)
        let closing = watch(chat, row.id)
        let closed = try #require(chat.line(row.id))
        #expect(closing.released)
        #expect(closing.ys.allSatisfy { abs($0 - before.y) <= 1 }, "the line moved while closing: from \(before.y) through \(closing.ys)")
        #expect(abs(closed.y - before.y) <= 1)
        #expect(abs(closed.height - before.height) <= 1, "back to its line: \(closed.height), was \(before.height)")
        #expect(closing.folded)
        #expect(Set(closing.heights.map { Int($0) }).count > 3, "it passed through heights between: \(closing.heights)")
        #expect(!closing.followed, "the transcript never followed its newest row during the close")
    }

    /// Resting on the newest row: an open keeps the line (the newest row is pushed down and the
    /// view stops following it); closing it again lands back on the newest row, which follows again.
    @Test func atTheNewestRowTheLineStaysAndTheChatFollowsAgainWhenBackAtTheBottom() throws {
        let chat = try chat(reducesMotion: false)
        defer { chat.window.isHidden = true }
        #expect(chat.surface.following)
        let lowest = chat.scroll.contentOffset.y + chat.scroll.bounds.height - 200
        let row = try #require(chat.list.demoDisclosure(nearContentY: lowest))
        let before = try #require(chat.line(row.id))

        chat.list.context.toggleFold(row: row.id, key: row.key, open: true)
        let opening = watch(chat, row.id)
        #expect(opening.released)
        #expect(opening.ys.allSatisfy { abs($0 - before.y) <= 1 }, "the line moved while opening: from \(before.y) through \(opening.ys)")
        #expect(!opening.followed, "no re-pin to the newest row while the body opened")
        #expect(!chat.surface.following, "the open pushed the newest row down: the view stays")

        chat.list.context.toggleFold(row: row.id, key: row.key, open: false)
        let closing = watch(chat, row.id)
        #expect(closing.released)
        #expect(closing.ys.allSatisfy { abs($0 - before.y) <= 1 }, "the line moved while closing: from \(before.y) through \(closing.ys)")
        #expect(chat.surface.following, "back on the newest row, the chat follows it again")
    }

    @Test func withReduceMotionTheBodyOpensAndClosesAtOnce() throws {
        let chat = try chat(reducesMotion: true)
        defer { chat.window.isHidden = true }
        readMiddle(chat)
        let row = try toolRow(chat)
        let before = try #require(chat.line(row.id))

        toggleWithoutMotion(chat, row: row.id, key: row.key, open: true)
        let opening = watch(chat, row.id, frames: 30)
        let opened = try #require(chat.line(row.id))
        #expect(opening.released, "the hold lets go on the next turns of the main loop")
        #expect(!opening.folded, "no spring")
        #expect(opened.height > before.height + 100)
        // At once: the first frame drawn after the tap already has the open height.
        #expect(opening.heights.dropFirst().allSatisfy { abs($0 - opened.height) <= 0.5 }, "heights \(opening.heights)")
        #expect(opening.ys.allSatisfy { abs($0 - before.y) <= 1 }, "the line moved: from \(before.y) through \(opening.ys)")
        #expect(!opening.followed)

        toggleWithoutMotion(chat, row: row.id, key: row.key, open: false)
        let closing = watch(chat, row.id, frames: 30)
        let closed = try #require(chat.line(row.id))
        #expect(closing.released)
        #expect(!closing.folded)
        #expect(abs(closed.height - before.height) <= 1)
        #expect(closing.heights.dropFirst().allSatisfy { abs($0 - closed.height) <= 0.5 }, "heights \(closing.heights)")
        #expect(closing.ys.allSatisfy { abs($0 - before.y) <= 1 }, "the line moved: from \(before.y) through \(closing.ys)")
    }
}
#endif
