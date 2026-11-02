import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The Chief's messages to its agents and their reports fold into one row per answer; a click on
/// a click on that row expands or collapses it (user 2026-10-30: "i want to be able to monitor the
/// messages you send to other agents better", and reports should reach the user by themselves).
@MainActor @Suite(.serialized) struct HomeAgentMessageFoldTests {
    init() {
        HomeMarkdownPolicy.install()
        HomeAgentFoldRowProvider.install()
    }

    static let group = "0123456789abcdef"

    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    final class Recorder: ChatIntents {
        var rows: [ID] = []
        func threadMovedByUser() {}
        func messageLink(_ id: ID) -> String? { nil }
        func send() -> String? { nil }
        func react(_ ref: MessagesLabHome.PartRef, _ kind: MessagesLabHome.Reaction.Kind) {}
        var canReact: Bool { false }
        var canReply: Bool { false }
        func pickAttachments() {}
        func takeAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func acceptsAttachments(from pasteboard: NSPasteboard) -> Bool { false }
        func statusLineClicked(_ rect: CGRect, in view: NSView) {}
        func draftChanged() {}
        func linkTapped(_ ref: MessagesLabHome.PartRef, url: String) {}
        func canCancelSend(_ message: ID) -> Bool { false }
        func cancelSend(_ message: ID) {}
        func canRetrySend(_ message: ID) -> Bool { false }
        func retrySend(_ message: ID) {}
        func deleteFailedSend(_ message: ID) {}
        func openAttachment(_ message: ID, _ attachment: ID) {}
        func toggleVideo(_ ref: MessagesLabHome.PartRef, _ attachment: ID) {}
        func videoState(_ ref: MessagesLabHome.PartRef) -> HomeVideoState { .poster }
        func agentRowClicked(_ message: ID) -> Bool { rows.append(message); return true }
        func scrolled() {}
        func rowsPlaced() {}
    }

    @Test func foldAndNotesRowsAreMutedLinesWithNoLink() {
        let folded = HomeMapping.agentMessageText(.init(group: Self.group, kind: .fold(count: 3, peers: ["a917", "a_1"], expanded: false)))
        #expect(folded.hasPrefix("*▸ "))
        #expect(folded.hasSuffix("a917, a\\_1"))
        #expect(folded.contains("3"))
        #expect(!folded.contains("]("))
        let open = HomeMapping.agentMessageText(.init(group: Self.group, kind: .fold(count: 3, peers: ["a917"], expanded: true)))
        #expect(open.hasPrefix("*▾ ") && !open.contains("a917") && !open.contains("]("))
        let notes = HomeMapping.agentMessageText(.init(group: Self.group, kind: .notes(
            count: 5, peers: ["a1", "a2"], reason: .stopped(session: "Disconnected"), expanded: false)))
        #expect(notes.hasPrefix("*▸ ") && notes.contains("5") && notes.hasSuffix("`a1` `a2`") && !notes.contains("]("))
        let mixed = HomeMapping.agentMessageText(.init(group: Self.group, kind: .notes(count: 2, peers: ["a1"], reason: nil, expanded: true)))
        #expect(mixed.hasPrefix("*▾ ") && mixed.contains("2") && !mixed.contains("a1"))
        let note = HomeMapping.agentMessageText(.init(group: Self.group, kind: .note(
            peer: "a1", reason: .gone, text: "gone: its session no longer exists, so no report will come")))
        #expect(note == "`a1` *gone: its session no longer exists, so no report will come*")
        let message = HomeMapping.agentMessageText(.init(group: Self.group, kind: .message(
            from: "Chief", to: "a917", outgoing: true, text: "Reserve [cmux12s](https://github.com/manaflow-ai/cmux)")))
        #expect(message == "**Chief → a917**\nReserve [cmux12s](https://github.com/manaflow-ai/cmux)")
    }

    /// User 2026-10-31 (msg 19414): the fold header is a muted caption line with a chevron and plain
    /// chips, not a link in a gray bubble.
    @Test func foldAndNotesRowsAreCaptionLinesNotBubbles() throws {
        let fold = HomeAgentMessageRow(group: Self.group, kind: .fold(count: 3, peers: ["a957", "a958"], expanded: false))
        let part = try #require(HomeAgentFoldRowProvider.part(fold))
        guard case let .custom(custom) = part else { Issue.record("not a drawn row"); return }
        #expect(custom.kind == HomeAgentFoldRowProvider.kind)
        let provider = try #require(HomeAgentFoldRowProvider.installed)
        #expect(provider.layout(for: custom) == .fullWidth)
        #expect(provider.plainText(custom) == "\(CmuxStrings.showAgentMessages(3)) · a957, a958")
        #expect(provider.measure(custom, maxWidth: 400).height == HomeAgentFoldRowProvider.height)
        let open = try #require(HomeAgentFoldRowProvider.part(.init(group: Self.group, kind: .fold(count: 3, peers: ["a957"], expanded: true))))
        guard case let .custom(openCustom) = open else { Issue.record("not a drawn row"); return }
        #expect(provider.plainText(openCustom) == CmuxStrings.hideAgentMessages(3))
        let notes = try #require(HomeAgentFoldRowProvider.part(.init(group: Self.group, kind: .notes(
            count: 5, peers: ["a1", "a2", "a3", "a4", "a5"], reason: .stopped(session: "Disconnected"), expanded: false))))
        guard case let .custom(notesCustom) = notes else { Issue.record("not a drawn row"); return }
        #expect(provider.plainText(notesCustom) == "\(CmuxStrings.agentNotes(.stopped(session: "Disconnected"), 5)) · a1, a2, a3, a4, a5")
        #expect(HomeAgentFoldRowProvider.part(.init(group: Self.group, kind: .message(from: "a1", to: "Chief", outgoing: false, text: "hi"))) == nil)
        // An opened note is a caption line too, with no chevron, so opening the notes brings back no bubbles.
        let note = try #require(HomeAgentFoldRowProvider.part(.init(group: Self.group, kind: .note(peer: "a1", reason: .gone, text: "gone: no report will come"))))
        guard case let .custom(noteCustom) = note else { Issue.record("not a drawn row"); return }
        #expect(provider.plainText(noteCustom) == "a1 · gone: no report will come")
        #expect(HomeAgentFoldRowProvider.payload(noteCustom)?.chevron == false)
    }

    @Test func captionKeepsChipsThatFitAndCountsTheRest() throws {
        let payload = HomeAgentFoldRowProvider.Payload(open: false, label: "Disconnected (8)", chips: (1...8).map { "a90\($0)" })
        let wide = HomeAgentFoldLine(payload, width: 900)
        #expect(wide.chips.count == 8 && wide.more == nil)
        let narrow = HomeAgentFoldLine(payload, width: 220)
        #expect(narrow.chips.count < 8)
        #expect(narrow.more?.string == "+\(8 - narrow.chips.count)")
    }

    @Test func captionDrawsInk() throws {
        let payload = HomeAgentFoldRowProvider.Payload(open: false, label: "Agent messages (3)", chips: ["a957"])
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 300, height: 22, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: 22)
        ctx.scaleBy(x: 1, y: -1)
        HomeAgentFoldLine(payload, width: 300).draw(ctx, at: .zero)
        let image = try #require(ctx.makeImage())
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(data.contains { $0 > 0 }, "the caption drew nothing")
    }

    @Test func threeHundredAgentNamesFitOneCompactFoldLabel() {
        let names = (0..<300).map { "a\($0)" }
        let folded = HomeMapping.agentMessageText(.init(group: Self.group,
            kind: .fold(count: 300, peers: names, expanded: false)))
        #expect(folded.contains("300"))
        #expect(folded.contains("a0, a1, a2, …"))
        #expect(!folded.contains("a299"))
        #expect(!folded.contains("]("))
        #expect(folded.count < 140)
        let expanded = HomeMapping.agentMessageText(.init(group: Self.group,
            kind: .fold(count: 300, peers: names, expanded: true)))
        #expect(expanded.contains("300"))
        #expect(!expanded.contains("a299"))
        let notes = HomeMapping.agentMessageText(.init(group: Self.group, kind: .notes(
            count: 300, peers: names, reason: .stopped(session: "Disconnected"), expanded: false)))
        #expect(notes.contains("300") && notes.hasSuffix("`a0` `a1` `a2` …") && !notes.contains("a299"))
    }

    @Test func aClickOnTheFoldRowTogglesItsGroupAndOpensNothingElse() throws {
        _ = NSApplication.shared
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var fold = TranscriptItem(key: IdempotencyKey("agent-messages:\(Self.group)"), seq: nil, author: chief,
                                  parts: [.text("▸ a917 · a938")], createdAt: base.addingTimeInterval(1), delivery: .committed)
        fold.isReadOnly = true
        fold.agentMessage = HomeAgentMessageRow(group: Self.group, kind: .fold(count: 2, peers: ["a917", "a938"], expanded: false))
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief, parts: [.text("I told two agents.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            fold,
        ]
        let summary = ConversationSummary(id: ConversationID("conv_fold"), title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_fold"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 560, height: 360)), wake: NoWake())
        window.contentView = controller.host
        let recorder = Recorder()
        controller.intents = recorder
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        var opened: [URL] = []
        controller.onOpenLink = { url, _ in opened.append(url) }
        controller.onAppLink = { opened.append($0) }

        let foldID = HomeMapping.id(fold, aliases: [:])
        let p = try #require(point(in: controller, on: foldID), "no point is on the fold row")
        controller.clicked(p)
        #expect(recorder.rows == [foldID])
        #expect(opened.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// The first point (scan order) on a row of message `message`.
    private func point(in controller: ChatController, on message: ID) -> CGPoint? {
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) {
                let p = CGPoint(x: x, y: y)
                if controller.demo?.hit(p)?.row.ref.messageId == message { return p }
            }
        }
        return nil
    }
}
