#if os(iOS)
import QuartzCore
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-17: "the gui is fine on phone other than the jitter on load sometimes and layout
/// shift and the lack of themeing/background inheriting (these need to be improved)".
///
/// The layout-shift harness. The real transcript controller runs in a window with a 60-turn chat
/// shaped like agent work (a thought, a read, an edit, a command with output, a markdown answer
/// with a code block and a table). A display link samples every display frame: each row on screen,
/// its drawn (presentation) top in window coordinates. A frame is a shift when a row that was on
/// screen in the frame before moved by more than 0.5 pt with no scroll of the reader's:
///
/// - Load (the chat opens with its turns kept, and opens before its history lands): no row on screen
///   moves at all.
/// - Streaming, the reader on the newest turn: the transcript follows the answer as it grows, so the
///   rows on screen move up together by the answer's growth. A shift is a row moving by a different
///   amount than another (a row re-measured, a late height, a jump between two places).
/// - Streaming, the reader scrolled up: nothing they see moves.
///
/// Each count is printed as one `LAYOUT-SHIFT` line (the PR's before and after table reads them).
@MainActor
@Suite(.serialized) struct TranscriptLayoutShiftTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_700_000_000)
    static let turns = 60

    /// The list rig's replayed turns (`MockAgentSession.replayStressTurns`), without its 2,400-line diff.
    static func history(turns: Int) -> [AgentSessionEvent] {
        (0 ..< turns).flatMap { index -> [AgentSessionEvent] in
            let turnID = "stress-\(index)"
            return [
                .userMessage(text: MockStressContent.prompt(index), promptId: "p-\(turnID)", turnId: turnID, attachments: [], at: at),
                .turnStarted(turnId: turnID, at: at),
                .update(.agentThoughtChunk(text: MockStressContent.thought(index))),
                .update(.toolCall(ACPToolCall(id: "\(turnID)-read", title: "Read LinkDialer.swift", kind: .read, status: .completed,
                                              content: [.content(.text(MockStressContent.code(lines: 12, seed: index)))],
                                              locations: [.init(path: "CmuxMobileTransport/LinkDialer.swift")]))),
                .update(.toolCall(ACPToolCall(id: "\(turnID)-edit", title: "Edit Stress\(index).swift", kind: .edit, status: .completed,
                                              content: [.diff(path: "Sources/Stress\(index).swift",
                                                              oldText: MockStressContent.code(lines: 30, seed: index),
                                                              newText: MockStressContent.code(lines: 30, seed: index, edited: true))]))),
                .update(.toolCall(ACPToolCall(id: "\(turnID)-run", title: "swift test --filter Link", kind: .execute, status: .completed,
                                              content: [.content(.text(MockStressContent.testOutput(index)))],
                                              rawInput: .object(["command": .string("swift test --filter Link")])))),
                .update(.agentMessageChunk(text: MockStressContent.answer(index), messageId: "\(turnID)-m")),
                .turnResult(turnId: turnID, status: .completed, errorText: nil, at: at.addingTimeInterval(1)),
            ]
        }
    }

    /// The streamed answer: markdown with bold text, code blocks, tables and lists, in 12-character
    /// tokens (one per display frame, about 720 characters a second).
    static let streamed: [String] = {
        let answer = Array((0 ..< 6).map { MockStressContent.answer($0) }.joined(separator: "\n\n"))
        return stride(from: 0, to: answer.count, by: 12).map { String(answer[$0 ..< min($0 + 12, answer.count)]) }
    }()

    enum Rule {
        /// Any row on screen that moves is a shift.
        case still
        /// Rows on screen may move together (following the newest row); one moving apart is a shift.
        case together
    }

    /// Samples the rows on screen every display frame and counts the frames in which one moved.
    @MainActor final class Sampler: NSObject {
        let controller: ChatTranscriptController
        let scroll: UIScrollView
        var rule: Rule
        /// Called after each sample (the streaming test feeds one token per frame here).
        var onFrame: (() -> Void)?
        private(set) var frames = 0
        private(set) var shifts = 0
        private(set) var log: [String] = []
        private var last: [String: CGFloat] = [:]
        private var link: CADisplayLink?
        private var list: ChatTranscriptList { controller.transcriptList }

        init(controller: ChatTranscriptController, scroll: UIScrollView, rule: Rule) {
            self.controller = controller
            self.scroll = scroll
            self.rule = rule
        }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        /// The next frame starts a new baseline (a programmatic scroll the test made, not a shift).
        func rebase() { last = [:] }

        /// The rows on screen and their drawn tops in the window, from the layers as drawn.
        func sample() -> [String: CGFloat] {
            let offset = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
            let top = scroll.adjustedContentInset.top
            let bottom = scroll.bounds.height - scroll.adjustedContentInset.bottom
            var tops: [String: CGFloat] = [:]
            for id in list.visibleRowIDs {
                guard let cell = list.cell(for: id), !cell.isHidden else { continue }
                let frame = cell.layer.presentation()?.frame ?? cell.frame
                let y = frame.minY - offset
                guard y + frame.height > top, y < bottom else { continue }
                tops[id] = y
            }
            return tops
        }

        @objc func tick(_ link: CADisplayLink) {
            frames += 1
            let now = sample()
            defer {
                last = now
                onFrame?()
            }
            // The reader's own scroll moves rows; it is not a shift.
            guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
            var moved: [(id: String, delta: CGFloat)] = []
            for (id, y) in now {
                guard let before = last[id] else { continue }
                moved.append((id, y - before))
            }
            guard !moved.isEmpty else { return }
            let shifted: Bool
            switch rule {
            case .still:
                shifted = moved.contains { abs($0.delta) > 0.5 }
            case .together:
                let deltas = moved.map(\.delta)
                shifted = (deltas.max() ?? 0) - (deltas.min() ?? 0) > 0.5
            }
            guard shifted else { return }
            shifts += 1
            if log.count < 40 {
                let rows = moved.filter { abs($0.delta) > 0.5 }.sorted { (now[$0.id] ?? 0) < (now[$1.id] ?? 0) }
                    .prefix(6).map { String(format: "%@ %+.1f", $0.id, $0.delta) }.joined(separator: ", ")
                log.append("frame \(frames): \(rows)")
            }
        }

        /// Waits `count` display frames (bounded by a wall-clock deadline).
        func wait(frames count: Int) async {
            let target = frames + count
            let deadline = ContinuousClock.now + .seconds(Double(count) / 20 + 5)
            while frames < target, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    struct Chat {
        let controller: ChatTranscriptController
        let store: AgentChatStore
        let surface: AgentChatSurface
        let scroll: UIScrollView
        let window: UIWindow
        let sampler: Sampler
    }

    /// The chat in a window, sampled from its first frame. `kept`: its turns are in the store before
    /// it opens (a reopened chat); otherwise its history lands a few frames after it opened.
    func open(kept: Bool, rule: Rule) async throws -> Chat {
        let store = AgentChatStore(source: Silent())
        store.nextFrame = nil
        if kept { store.apply(.batch(Self.history(turns: Self.turns))) }
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(placement: .owned, surface: surface, store: store,
                                                  empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil)
        controller.reducesMotion = { false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptCollectionView }.first)
        let sampler = Sampler(controller: controller, scroll: scroll, rule: rule)
        sampler.start()
        window.makeKeyAndVisible()
        let chat = Chat(controller: controller, store: store, surface: surface, scroll: scroll, window: window, sampler: sampler)
        if !kept {
            await sampler.wait(frames: 6)
            store.apply(.batch(Self.history(turns: Self.turns)))
        }
        return chat
    }

    func report(_ name: String, _ sampler: Sampler) {
        print("LAYOUT-SHIFT \(name) shifted=\(sampler.shifts) frames=\(sampler.frames)")
        for line in sampler.log { print("LAYOUT-SHIFT \(name)   \(line)") }
    }

    /// A running turn's work, one step per display frame: a streamed thought, a read and an edit that
    /// run and then finish (the edit with its diff), then the answer's tokens.
    static func liveTurn(_ turn: String) -> [[AgentSessionEvent]] {
        var steps: [[AgentSessionEvent]] = []
        let thought = Array(MockStressContent.thought(7))
        for start in stride(from: 0, to: thought.count, by: 16) {
            steps.append([.update(.agentThoughtChunk(text: String(thought[start ..< min(start + 16, thought.count)])))])
        }
        let wait: [[AgentSessionEvent]] = Array(repeating: [], count: 8)
        steps.append([.update(.toolCall(ACPToolCall(id: "\(turn)-read", title: "Read LinkDialer.swift", kind: .read, status: .inProgress,
                                                    locations: [.init(path: "CmuxMobileTransport/LinkDialer.swift")])))])
        steps += wait
        steps.append([.update(.toolCallUpdate(ACPToolCallUpdate(toolCallId: "\(turn)-read", status: .completed,
                                                                content: [.content(.text(MockStressContent.code(lines: 12, seed: 3)))])))])
        steps.append([.update(.toolCall(ACPToolCall(id: "\(turn)-edit", title: "Edit LinkDialer.swift", kind: .edit, status: .inProgress)))])
        steps += wait
        steps.append([.update(.toolCallUpdate(ACPToolCallUpdate(
            toolCallId: "\(turn)-edit", status: .completed,
            content: [.diff(path: "CmuxMobileTransport/LinkDialer.swift", oldText: MockStressContent.code(lines: 30, seed: 3),
                            newText: MockStressContent.code(lines: 30, seed: 3, edited: true))])))])
        steps += wait
        for token in streamed { steps.append([.update(.agentMessageChunk(text: token, messageId: "\(turn)-m"))]) }
        return steps
    }

    /// Streams a new turn, one step per display frame, then ends the turn.
    func stream(_ chat: Chat, turn: String) async {
        chat.store.apply(.batch([
            .userMessage(text: "Walk me through the retry change", promptId: "p-\(turn)", turnId: turn, attachments: [], at: Self.at),
            .turnStarted(turnId: turn, at: Self.at),
        ]))
        let live = Self.liveTurn(turn)
        var steps = live[...]
        let store = chat.store
        chat.sampler.onFrame = {
            guard let step = steps.popFirst(), !step.isEmpty else { return }
            store.apply(.batch(step))
        }
        await chat.sampler.wait(frames: live.count + 4)
        chat.sampler.onFrame = nil
        chat.store.apply(.turnResult(turnId: turn, status: .completed, errorText: nil, at: Self.at))
        await chat.sampler.wait(frames: 60)
    }

    @Test func noRowMovesWhileAKeptChatOpens() async throws {
        let chat = try await open(kept: true, rule: .still)
        defer { chat.sampler.stop(); chat.window.isHidden = true }
        await chat.sampler.wait(frames: 180)
        report("load-kept", chat.sampler)
        #expect(chat.sampler.frames >= 150, "the display link ran: \(chat.sampler.frames) frames")
        #expect(chat.sampler.shifts == 0, "frames in which a row on screen moved while the chat opened: \(chat.sampler.shifts)\n\(chat.sampler.log.joined(separator: "\n"))")
    }

    @Test func noRowMovesWhenTheHistoryLandsAfterTheChatOpened() async throws {
        let chat = try await open(kept: false, rule: .still)
        defer { chat.sampler.stop(); chat.window.isHidden = true }
        await chat.sampler.wait(frames: 180)
        report("load-history", chat.sampler)
        #expect(chat.sampler.frames >= 150, "the display link ran: \(chat.sampler.frames) frames")
        #expect(chat.sampler.shifts == 0, "frames in which a row on screen moved as the history landed: \(chat.sampler.shifts)\n\(chat.sampler.log.joined(separator: "\n"))")
    }

    @Test func rowsMoveTogetherWhileTheAnswerStreamsAtTheNewestTurn() async throws {
        let chat = try await open(kept: true, rule: .together)
        defer { chat.sampler.stop(); chat.window.isHidden = true }
        await chat.sampler.wait(frames: 120)
        let before = chat.sampler.shifts
        await stream(chat, turn: "live-1")
        let shifts = chat.sampler.shifts - before
        print("LAYOUT-SHIFT stream-following shifted=\(shifts) frames=\(Self.liveTurn("x").count + 64)")
        report("stream-following(all)", chat.sampler)
        #expect(chat.surface.following, "the reader stayed on the newest turn")
        #expect(shifts == 0, "frames in which rows on screen moved apart while the answer streamed: \(shifts)\n\(chat.sampler.log.joined(separator: "\n"))")
    }

    @Test func nothingMovesWhileTheAnswerStreamsBelowAReaderScrolledUp() async throws {
        let chat = try await open(kept: true, rule: .still)
        defer { chat.sampler.stop(); chat.window.isHidden = true }
        await chat.sampler.wait(frames: 120)
        // The reader scrolled two screens up from the newest turn.
        chat.surface.following = false
        chat.scroll.contentOffset.y = max(-chat.scroll.adjustedContentInset.top,
                                          chat.scroll.contentOffset.y - 2 * chat.scroll.bounds.height)
        await chat.sampler.wait(frames: 30)
        chat.sampler.rebase()
        let before = chat.sampler.shifts
        await stream(chat, turn: "live-2")
        let shifts = chat.sampler.shifts - before
        print("LAYOUT-SHIFT stream-scrolled-up shifted=\(shifts) frames=\(Self.liveTurn("x").count + 64)")
        report("stream-scrolled-up(all)", chat.sampler)
        #expect(shifts == 0, "frames in which a row moved under a reader scrolled up while the answer streamed: \(shifts)\n\(chat.sampler.log.joined(separator: "\n"))")
    }
}
#endif
