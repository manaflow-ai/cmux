#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Aziz 2026-11-03 ("the animation for the disclosure group rows aren't very pleasing; some
/// disclosure groups don't animatedly open up while others do"): a finished tool row, tool group or
/// thought is drawn natively at rest and swapped for its open SwiftUI view on a tap, which had
/// nothing to animate, so it opened in one frame while a SwiftUI row (a running group, any row at an
/// accessibility size) animated; and a SwiftUI row's new height applied on the next layout pass, so
/// the rows below jumped while its body faded in or out over them. Every disclosure now opens and
/// closes on the same spring: the row's drawn height passes through in-between values, and the
/// row below never starts above the row's drawn bottom.
///
/// Each check runs the real transcript controller in a window and reads the rows' drawn
/// (presentation) frames frame by frame, as `NativeRowFoldTests` does.
@MainActor
@Suite(.serialized) struct DisclosureAnimationTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// Turns of a prompt, a thought, a group of a read and a command, a lone read and an answer.
    static func events(turns: Int, prompt: (Int) -> String = { "prompt \($0)" }) -> [AgentSessionEvent] {
        (0 ..< turns).flatMap { n -> [AgentSessionEvent] in
            let output = (0 ..< 12).map { "let line\($0) = \(n)" }.joined(separator: "\n")
            return [
                .userMessage(text: prompt(n), promptId: "p\(n)", turnId: "t\(n)", attachments: [], at: at),
                .turnStarted(turnId: "t\(n)", at: at),
                .update(.agentThoughtChunk(text: "The dialer keeps one attempt in flight; check how it schedules retries (\(n)). "
                    + String(repeating: "Then the relay path and the WireGuard handshake. ", count: 4))),
                .update(.toolCall(ACPToolCall(id: "g\(n)a", title: "Read a\(n).swift", kind: .read, status: .completed,
                                              content: [.content(.text(output))], locations: [.init(path: "Sources/a\(n).swift")]))),
                .update(.toolCall(ACPToolCall(id: "g\(n)b", title: "swift test", kind: .execute, status: .completed,
                                              content: [.content(.text(output))], rawInput: .object(["command": .string("swift test")])))),
                .update(.agentMessageChunk(text: "Checked the dialer (\(n)).", messageId: "m\(n)a")),
                .update(.toolCall(ACPToolCall(id: "c\(n)", title: "Read b\(n).swift", kind: .read, status: .completed,
                                              content: [.content(.text(output))], locations: [.init(path: "Sources/b\(n).swift")]))),
                .update(.agentMessageChunk(text: "Answer \(n): the dialer retries with backoff.", messageId: "m\(n)b")),
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

        /// Row `id`'s drawn top and bottom in the scroll view's own frame.
        func span(_ id: String) -> (top: CGFloat, bottom: CGFloat)? {
            guard let cell = list.cell(for: id) else { return nil }
            let frame = cell.layer.presentation()?.frame ?? cell.frame
            let offset = scroll.layer.presentation()?.bounds.origin.y ?? scroll.contentOffset.y
            return (frame.minY - offset, frame.maxY - offset)
        }

        func frame() async {
            try? await Task.sleep(for: .milliseconds(16))
            controller.view.layoutIfNeeded()
            CATransaction.flush()
        }

        func frames(_ count: Int) async {
            for _ in 0 ..< count { await frame() }
        }

        /// The rows wholly on screen, top first.
        func onScreen() -> [String] {
            let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
            let bottom = scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom
            return list.visibleRowIDs.filter { id in
                guard let cell = list.cell(for: id) else { return false }
                return cell.frame.minY >= top && cell.frame.maxY <= bottom
            }
        }

        /// The disclosure key of a thought, group or tool row.
        func key(_ id: String) -> String? {
            switch list.row(id)?.kind {
            case .thought: "thought-\(id)"
            case .toolGroup(let calls, _): "group-\(calls.first?.id ?? "")"
            case .tool(let call): "tool-\(call.id)"
            default: nil
            }
        }

        /// The row after `id` in the transcript.
        func next(after id: String) -> String? {
            let ids = list.visibleRowIDs
            return ids.firstIndex(of: id).flatMap { $0 + 1 < ids.count ? ids[$0 + 1] : nil }
        }
    }

    func chat(prompt: @escaping (Int) -> String = { "prompt \($0)" }, turns: Int = 30) async throws -> Chat {
        let store = AgentChatStore(source: Silent())
        store.nextFrame = nil
        store.apply(.batch(Self.events(turns: turns, prompt: prompt)))
        let surface = AgentChatSurface()
        let controller = ChatTranscriptController(placement: .owned, surface: surface, store: store,
                                                  empty: AnyView(EmptyView()), dock: AnyView(Color.clear.frame(height: 96)), jump: nil)
        controller.reducesMotion = { false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let scroll = try #require(controller.view.subviews.lazy.compactMap { $0 as? ChatTranscriptCollectionView }.first)
        let chat = Chat(controller: controller, surface: surface, scroll: scroll, window: window)
        for _ in 0 ..< 150 where scroll.contentSize.height < scroll.bounds.height * 4 { await chat.frame() }
        try #require(scroll.contentSize.height >= scroll.bounds.height * 4, "content measured \(scroll.contentSize.height)")
        await chat.frames(20)
        return chat
    }

    /// What one open or close drew: the row's drawn heights, and how far the row below started
    /// above the row's drawn bottom on its worst frame (0 when it never did).
    struct Fold {
        var heights: [CGFloat] = []
        var worstOverlap: CGFloat = 0
        /// Per frame: the row's drawn top and bottom and the next row's drawn top.
        var trace: [String] = []
        var start: CGFloat = 0
        var end: CGFloat = 0

        /// Frames drawn strictly between the start and end heights (more than 2 pt from both). A snap
        /// draws none; the tests ask for two, since one sampled frame on a loaded host can span most
        /// of the 0.35 s spring (a fleet run drew 32, 308, 344, 350).
        var between: Int {
            let low = min(start, end) + 2, high = max(start, end) - 2
            return heights.filter { $0 > low && $0 < high }.count
        }
    }

    /// Plays `toggle` and samples every frame until the hold lets go (at least 60 frames).
    func fold(_ chat: Chat, _ id: String, _ toggle: () -> Void) async throws -> Fold {
        var fold = Fold()
        fold.start = try #require(chat.span(id)).bottom - (try #require(chat.span(id))).top
        let below = chat.next(after: id)
        toggle()
        for frame in 0 ..< 240 where frame < 60 || chat.controller.isHoldingFold {
            await chat.frame()
            guard let span = chat.span(id) else { continue }
            fold.heights.append(span.bottom - span.top)
            if let below, let next = chat.span(below) {
                fold.worstOverlap = max(fold.worstOverlap, span.bottom - next.top)
                fold.trace.append("\(Int(span.top))-\(Int(span.bottom))/\(Int(next.top))\(chat.list.cell(for: id) is ChatNativeRowCell ? "n" : "s")")
            }
        }
        let end = try #require(chat.span(id))
        fold.end = end.bottom - end.top
        return fold
    }

    /// The row of `kind` lowest on screen (a native line at rest).
    func lowest(_ chat: Chat, _ kind: String) throws -> String {
        let ids = chat.onScreen().filter { id in
            switch chat.list.row(id)?.kind {
            case .thought: kind == "thought"
            case .toolGroup: kind == "group"
            case .tool: kind == "tool"
            default: false
            }
        }
        return try #require(ids.last, "a \(kind) row on screen")
    }

    /// A row whose disclosure changes while a spring runs but that the spring does not lay out
    /// (off screen here) takes its measured height for the new state when the spring ends, not
    /// the height it was held at.
    @Test func anOffscreenRowChangedDuringASpringTakesItsMeasuredHeight() async throws {
        let chat = try await chat()
        defer { chat.window.isHidden = true }
        let layout = chat.list.layout
        let disclosures = chat.surface.disclosures
        let hold = chat.list.context.foldHold
        let x = try lowest(chat, "group")
        let keyX = try #require(chat.key(x))
        // Open and close it once on screen, so both states are measured.
        _ = try await fold(chat, x) { toggleDisclosure(hold, key: keyX, in: disclosures) { disclosures.set(keyX, true) } }
        await chat.frames(10)
        let open = try #require(layout.height(of: x))
        _ = try await fold(chat, x) { toggleDisclosure(hold, key: keyX, in: disclosures) { disclosures.set(keyX, false) } }
        await chat.frames(10)
        let closed = try #require(layout.height(of: x))
        try #require(open > closed + 40, "the group opened: \(closed) -> \(open)")

        // Scrolled up until it is off screen, then opened along with a group on screen.
        chat.surface.following = false
        chat.scroll.contentOffset.y -= chat.scroll.bounds.height * 2.5
        await chat.frames(20)
        // Off screen: no visible cell (UIKit may keep a hidden one parked for reuse).
        let parked = chat.list.cell(for: x)
        try #require(!chat.scroll.visibleCells.contains { $0 === parked }, "the first group is off screen")
        let y = try lowest(chat, "group")
        let keyY = try #require(chat.key(y))
        _ = try await fold(chat, y) {
            toggleDisclosure(hold, key: keyY, in: disclosures) {
                disclosures.set(keyY, true)
                disclosures.set(keyX, true)
            }
        }
        await chat.frames(10)
        let after = try #require(layout.height(of: x))
        #expect(abs(after - open) <= 1, "the off-screen group is laid out at its open height \(open), not \(after) (held at \(closed))")
    }

    /// A second tap inside the spring starts a second settle: the first one's completion leaves
    /// the row settling (SwiftUI) until the second one ends, so it does not swap back to native
    /// mid-animation.
    @Test func aSecondTapKeepsTheRowSettlingUntilItsSpringEnds() {
        let disclosures = ChatDisclosures()
        disclosures.settle("tool-1", true)
        disclosures.settle("tool-1", true)
        let revision = disclosures.revision
        disclosures.settle("tool-1", false)
        #expect(disclosures.isSettling("tool-1"), "still settling after the first spring ends")
        #expect(disclosures.revision == revision, "no swap while a spring still runs")
        disclosures.settle("tool-1", false)
        #expect(!disclosures.isSettling("tool-1"))
        #expect(disclosures.revision != revision)
    }

    /// Native lines (a finished thought, group and tool row) tapped open and closed with their
    /// SwiftUI row's button: each opens and closes over several frames, with no row drawn over it.
    /// The tapped line's pixels (its first 22 pt, left of the trailing duration and chevron) as
    /// drawn now, in grays.
    @MainActor func headerStrip(_ chat: Chat, _ id: String) -> [UInt8]? {
        guard let cell = chat.list.cell(for: id), cell.bounds.width > 100 else { return nil }
        let size = CGSize(width: cell.bounds.width - 90, height: 22)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // The layer tree as SwiftUI laid it out this frame (a snapshot of the screen is blank in
        // the test host).
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            cell.layer.render(in: context.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// 2026-11-04 (the user): "the row itself shouldn't move and it should only reveal whatever is
    /// under it". A disclosure's line stays where it is drawn while its body opens or closes: the
    /// hosting view centered a row's SwiftUI content in its cell while the content's animated height
    /// differed from the cell's, so the line slid down and back on open and up out of the clipped
    /// cell on close.
    @Test(arguments: ["thought", "group", "tool"])
    func aDisclosureLineStaysPutWhileItsBodyReveals(_ kind: String) async throws {
        let chat = try await chat()
        defer { chat.window.isHidden = true }
        let id = try lowest(chat, kind)
        let key = try #require(chat.key(id))
        let disclosures = chat.surface.disclosures
        let hold = chat.list.context.foldHold
        for open in [true, false] {
            toggleDisclosure(hold, key: key, in: disclosures) { disclosures.set(key, open) }
            await chat.frame()
            let first = try #require(headerStrip(chat, id), "\(kind)'s line is drawn")
            #expect(Set(first).count > 8, "the strip has the line's text in it")
            var worst = 0.0, at = 0
            for frame in 0 ..< 240 where frame < 40 || chat.controller.isHoldingFold {
                await chat.frame()
                guard let strip = headerStrip(chat, id), strip.count == first.count else { continue }
                let diff = zip(strip, first).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(strip.count)
                if diff > worst { worst = diff; at = frame }
            }
            #expect(worst < 2, "\(kind)'s line moved while it \(open ? "opened" : "closed"): mean change \(worst) on frame \(at)")
            await chat.frames(10)
        }
    }

    @Test(arguments: ["thought", "group", "tool"])
    func aNativeDisclosureOpensAndClosesOnTheSpring(_ kind: String) async throws {
        let chat = try await chat()
        defer { chat.window.isHidden = true }
        let id = try lowest(chat, kind)
        let native = try #require(chat.list.cell(for: id) as? ChatNativeRowCell, "a native \(kind) line at rest")
        let key = try #require(chat.key(id))

        let opening = try await fold(chat, id) { native.perform(.toggle(key)) }
        #expect(opening.end > opening.start + 40, "\(kind) opened: \(opening.start) -> \(opening.end)")
        #expect(opening.between >= 2, "\(kind) opened over several frames, not in one: \(opening.heights.map { Int($0) })")
        #expect(opening.worstOverlap <= 1, "the row below \(kind) started \(opening.worstOverlap) pt above its bottom while it opened: \(opening.trace)")
        #expect(!chat.controller.isHoldingFold, "the hold lets go")

        // Closed as the open SwiftUI row's own button does.
        let disclosures = chat.surface.disclosures
        let closing = try await fold(chat, id) {
            toggleDisclosure(chat.list.context.foldHold, key: key, in: disclosures) { disclosures.set(key, false) }
        }
        #expect(closing.end < closing.start - 40, "\(kind) closed: \(closing.start) -> \(closing.end)")
        #expect(closing.between >= 2, "\(kind) closed over several frames, not in one: \(closing.heights.map { Int($0) })")
        #expect(closing.worstOverlap <= 1, "the row below \(kind) started \(closing.worstOverlap) pt above its bottom while it closed: \(closing.trace)")
        await chat.frames(10)

        // A second open and close: both states were measured by now, and the list's reload used
        // to lay the row out at its measured height in one frame instead of on the spring.
        for open in [true, false] {
            let again = try await fold(chat, id) {
                toggleDisclosure(chat.list.context.foldHold, key: key, in: disclosures) { disclosures.set(key, open) }
            }
            let moved = open ? again.end > again.start + 40 : again.end < again.start - 40
            #expect(moved, "\(kind) \(open ? "reopened" : "closed again"): \(again.start) -> \(again.end)")
            #expect(again.between >= 2, "\(kind) \(open ? "reopened" : "closed again") over several frames, not in one: \(again.heights.map { Int($0) })")
            #expect(again.worstOverlap <= 1, "the row below \(kind) started \(again.worstOverlap) pt above its bottom on the second \(open ? "open" : "close"): \(again.trace)")
            await chat.frames(10)
        }
        if kind != "thought" {
            // A thought the person touched stays SwiftUI (`ChatNativeEligibility`); a closed tool row
            // or group is native again once settled.
            #expect(chat.list.cell(for: id) is ChatNativeRowCell, "a closed \(kind) is drawn natively again")
        }
    }

    /// The screenshot of 2026-11-03: a pasted raw log as a prompt drew past its bubble, over the
    /// thought, tool group and answer under it. UILabel's default line-break strategy wrapped it
    /// into more lines than the row was laid out for. Every label of a native prompt bubble fits
    /// its frame, and the row below starts under it.
    @Test func aPastedLogPromptDrawsInsideItsBubble() async throws {
        let shapes: [String] = [
            "2026-11-03T04:12:%02d.%03dZ INFO  link.dialer attempt=%d mac=Lawrence’s-MacBook-Pro rtt=41ms ✅",
            "\u{1B}[31merror\u{1B}[0m: frame header mismatch at offset %d (expected 9 bytes, got %d) 🔥🔥",
            "\tat CmuxMobileTransport.LinkDialer.connect(mac:timeout:) (LinkDialer.swift:%d:%d)",
            "警告: 接続がタイムアウトしました (試行 %d / %d) — 再試行します 🔁",
        ]
        let token: String = "payload=" + String(repeating: "deadbeef", count: 50)
        var lines: [String] = []
        for line in 0 ..< 120 {
            if line % 37 == 36 {
                lines.append(token)
            } else {
                let values: [CVarArg] = [line % 60, (line * 7) % 1000, line, line * 3]
                lines.append(String(format: shapes[line % shapes.count], arguments: values))
            }
        }
        let log: String = lines.joined(separator: "\n")
        let chat = try await chat(prompt: { (n: Int) -> String in n == 29 ? log : "prompt \(n)" })
        defer { chat.window.isHidden = true }
        // The log's prompt, scrolled to its top.
        let ids: [String] = chat.list.layout.items.map { (item: ChatTranscriptLayout.Item) -> String in item.id }
        let found: String? = ids.first { (id: String) -> Bool in
            guard case .prompt(let text, _, _, _) = chat.list.row(id)?.kind else { return false }
            return text == log
        }
        let id = try #require(found, "the log's prompt row")
        let top = try #require(chat.list.layout.top(of: id))
        chat.surface.following = false
        chat.scroll.contentOffset.y = top - 100
        await chat.frames(20)
        let cell = try #require(chat.list.cell(for: id) as? ChatNativeRowCell, "the prompt is a native bubble")
        let labels: [UILabel] = cell.contentView.subviews.compactMap { (view: UIView) -> UILabel? in
            guard let label = view as? UILabel, !label.isHidden, (label.attributedText?.length ?? 0) > 0 else { return nil }
            return label
        }
        try #require(!labels.isEmpty)
        for label in labels {
            let fits = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
            let frameHeight: CGFloat = label.bounds.height
            #expect(fits <= frameHeight + 1, "the label draws \(fits) pt in a \(frameHeight) pt frame")
            let labelBottom: CGFloat = label.frame.maxY
            let rowHeight: CGFloat = cell.bounds.height
            #expect(labelBottom <= rowHeight, "the label ends at \(labelBottom) in a \(rowHeight) pt row")
        }
        if let below = chat.next(after: id), let next = chat.list.cell(for: below) {
            #expect(next.frame.minY >= cell.frame.maxY - 0.5, "the row below starts under the bubble")
        }
    }
}
#endif
