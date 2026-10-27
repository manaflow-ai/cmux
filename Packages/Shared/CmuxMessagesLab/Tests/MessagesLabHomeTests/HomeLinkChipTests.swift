import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Links to cmux objects, files and GitHub objects show as chips in Home (Lawrence 2026-10-20: "a
/// badge or tag-type thing with a good icon … I can just click it … hover on it and it'll show a
/// preview"). plans/cmux-next/home-link-chips-DESIGN.md.
@Suite(.serialized) struct HomeLinkChipTests {
    init() { HomeMarkdownPolicy.install() }

    static let ws = "cmux://workspace/ws_0123456789abcdef0123456789abcdef"
    static let tab = "cmux://tab/tab_0123456789abcdef0123456789abcdef"

    @Test(arguments: [
        (ws, HomeLinkChipKind.workspace),
        ("cmux://pane/pane_0123456789abcdef0123456789abcdef", .pane),
        (tab, .tab),
        ("cmux://session/ses-01.a", .session),
        ("cmux://chief/0123abcd/session/s-81", .subagent),
        ("file:///Users/me/fun/REPORT.md", .markdown),
        ("file:///Users/me/fun/", .folder),
        ("file:///Users/me/fun/cmux", .folder),
        ("file:///Users/me/a.png", .image),
        ("file:///Users/me/a.swift", .code),
        ("file:///Users/me/a.zip", .file),
        ("https://github.com/manaflow-ai/cmux/pull/22245", .pullRequest),
        ("https://github.com/manaflow-ai/cmux/issues/2871", .issue),
        ("https://github.com/manaflow-ai/cmux/commit/0c78ed8b29864803ea5d163d132f9e06625363a4", .commit),
        ("https://github.com/manaflow-ai/cmux/actions/runs/39365550453", .run),
    ])
    func kindOfEachTarget(link: String, kind: HomeLinkChipKind) {
        #expect(HomeLinkChip.kind(for: link) == kind)
        #expect(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil, "\(kind.symbolName)")
    }

    @Test(arguments: ["https://example.com/a", "mailto:a@b.c", "https://github.com/manaflow-ai/cmux", "nonsense"])
    func aPlainLinkIsNoChip(link: String) {
        #expect(HomeLinkChip.kind(for: link) == nil)
    }

    /// The runs of the chip for `link` in `markdown` rendered with chips.
    private func chip(_ markdown: String) -> (text: String, runs: [TextRun]) {
        let (text, runs) = HomeMarkdown.render(markdown, chips: true)
        return (text, runs.filter { $0.chipKind != nil })
    }

    @Test func aWorkspaceLinkIsAChipWithAPadAndNoBreaks() throws {
        let (text, runs) = chip("Moved [Chief · tab audio](\(Self.ws)) to the top.")
        let run = try #require(runs.first)
        #expect(run.chipKind == .workspace)
        #expect(run.link == Self.ws)
        let shown = (text as NSString).substring(with: NSRange(location: run.start, length: runs.map(\.length).reduce(0, +)))
        // One leading pad for the icon, then the label with no-break spaces (it wraps as one unit).
        #expect(shown == "\u{00A0}Chief\u{00A0}·\u{00A0}tab\u{00A0}audio")
        #expect(text.hasPrefix("Moved \u{00A0}Chief"))
        #expect(text.hasSuffix(" to the top."))
    }

    @Test func aBareIdIsAChip() throws {
        let (_, runs) = chip("See ws_0123456789abcdef0123456789abcdef now.")
        #expect(runs.first?.chipKind == .workspace)
    }

    @Test func aWebLinkStaysText() {
        let (text, runs) = HomeMarkdown.render("[site](https://example.com) and [#22245](https://github.com/manaflow-ai/cmux/pull/22245)", chips: true)
        #expect(runs.first { $0.link == "https://example.com" }?.chipKind == nil)
        #expect(runs.first { $0.link?.hasSuffix("/pull/22245") == true }?.chipKind == .pullRequest)
        #expect(text.hasPrefix("site and \u{00A0}#22245"))
    }

    @Test func withoutChipsTheTextIsAsBefore() {
        let (text, runs) = HomeMarkdown.render("Moved [Chief · tab](\(Self.ws)).")
        #expect(text == "Moved Chief · tab.")
        #expect(runs.allSatisfy { $0.chipKind == nil })
    }

    @Test func aChipReservesItsIconWidth() throws {
        let plain = HomeMarkdown.render("[Chief](https://example.com)", chips: true)
        let chipped = HomeMarkdown.render("[Chief](\(Self.ws))", chips: true)
        let a = TextLayout.make(plain.text, runs: plain.runs, maxWidth: 400)
        let b = TextLayout.make(chipped.text, runs: chipped.runs, maxWidth: 400)
        #expect(b.width >= a.width + HomeLinkChip.iconSlot)
        let spans = b.chipSpans(line: 0)
        let span = try #require(spans.first)
        #expect(span.kind == .workspace)
        #expect(span.x0 < 1)
        #expect(span.x1 >= b.width - 0.5)
    }

    /// Lawrence 2026-10-20 ("These pills are extremely ugly … the font size needs to be the same
    /// … for now revert this change"): an agent's reply maps links with no chips. A subagent id
    /// stays a plain inline link: same text, no icon pad, no chip style, the body font, and as
    /// wide as the plain-link render.
    @Test func anAgentMessageMapsLinksAsPlainText() throws {
        let people = [CmuxHomeCore.Participant(id: ParticipantID("agent_chief"), kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = ConversationSummary(id: ConversationID("c"), title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        func mapped(_ text: String) throws -> (String, [TextRun]) {
            let item = TranscriptItem(key: IdempotencyKey("k"), seq: Seq(1), author: ParticipantID("agent_chief"),
                                      parts: [.text(text)], createdAt: base, delivery: .committed, messageID: MessageID("m"))
            guard case let .text(shown, runs)? = HomeMapping.projectedParts(item, summary: summary).parts.first else {
                Issue.record("no text part"); throw CancellationError()
            }
            return (shown, runs)
        }
        let (_, runs) = try mapped("a340: drag links to split; [the tab](\(Self.tab)).")
        let (agent, agentRuns) = try mapped("[a340](cmux://chief/0123abcd/session/s-81) is on it.")
        #expect(agent == "a340 is on it.")
        let link = try #require(agentRuns.first { $0.link != nil })
        #expect(link.link == "cmux://chief/0123abcd/session/s-81")
        #expect(link.start == 0 && link.length == 4)
        #expect((runs + agentRuns).allSatisfy { $0.chipKind == nil })
        // As wide as the plain-link render: no icon slot, no trailing pad.
        let (web, webRuns) = HomeMarkdown.render("[a340](cmux://chief/0123abcd/session/s-81) is on it.")
        let a = TextLayout.make(agent, runs: agentRuns, maxWidth: 400)
        let b = TextLayout.make(web, runs: webRuns, maxWidth: 400)
        #expect(abs(a.width - b.width) < 0.5)
        #expect(a.chipSpans(line: 0).isEmpty)
        // The body font on the id, as on the words around it.
        let attr = a.attributed(color: .white, linkColor: .white)
        let idFont = attr.attribute(.font, at: 1) as? NSFont
        let bodyFont = attr.attribute(.font, at: 6) as? NSFont
        #expect(idFont?.pointSize == bodyFont?.pointSize)
        #expect(attr.attribute(.kern, at: 0) as? CGFloat == attr.attribute(.kern, at: 6) as? CGFloat)
    }
}

/// The chip under the pointer: its URL, kind and rect on its line (the hover card's anchor), from a
/// real `ChatController` over a loaded conversation.
@MainActor @Suite(.serialized) struct HomeLinkChipHitTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// Chips are off in the transcript (Lawrence 2026-10-20, see anAgentMessageMapsLinksAsPlainText):
    /// a workspace link in a loaded conversation has no chip anywhere under the pointer.
    @Test func noChipIsUnderThePointer() throws {
        HomeMarkdownPolicy.install()
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief,
                                    parts: [.text("Done in [Chief · audio](\(HomeLinkChipTests.ws)) today.")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_1"))]
        let summary = ConversationSummary(id: ConversationID("conv_chip"), title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_chip"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()

        let b = controller.host.bounds
        var found: HomeLinkChipHit?
        scan: for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) {
                if let hit = controller.linkChip(at: CGPoint(x: x, y: y)) { found = hit; break scan }
            }
        }
        #expect(found == nil)
    }
}
