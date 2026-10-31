import AppKit
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The Chief's messages to its agents and their reports fold into one row per answer; a click on
/// that row's link expands or collapses it (user 2026-10-30: "i want to be able to monitor the
/// messages you send to other agents better", and reports should reach the user by themselves).
@MainActor @Suite(.serialized) struct HomeAgentMessageFoldTests {
    init() { HomeMarkdownPolicy.install() }

    static let group = "0123456789abcdef"
    static let link = HomeAgentMessageRow.toggleLink(group: group)

    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    final class Recorder: ChatIntents {
        var folds: [String] = []
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
        func toggleAgentMessages(_ group: String) { folds.append(group) }
        func scrolled() {}
        func rowsPlaced() {}
    }

    @Test func foldTextNamesItsAgentsAfterItsToggleLink() {
        let folded = HomeMapping.agentMessageText(.init(group: Self.group, kind: .fold(count: 3, peers: ["a917", "a_1"], expanded: false)))
        #expect(folded.contains("](\(Self.link))"))
        #expect(folded.hasSuffix("a917, a\\_1"))
        #expect(folded.contains("3"))
        let open = HomeMapping.agentMessageText(.init(group: Self.group, kind: .fold(count: 3, peers: ["a917"], expanded: true)))
        #expect(open.contains("](\(Self.link))"))
        #expect(!open.contains("a917"))
        let message = HomeMapping.agentMessageText(.init(group: Self.group, kind: .message(
            from: "Chief", to: "a917", outgoing: true, text: "Reserve [cmux12s](https://github.com/manaflow-ai/cmux)")))
        #expect(message == "**Chief → a917**\nReserve [cmux12s](https://github.com/manaflow-ai/cmux)")
        #expect(URL(string: Self.link)?.isCmuxAppLink == true)
        #expect(HomeLinkChip.kind(for: Self.link) == nil)
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

        let p = try #require(point(in: controller, opening: Self.link), "no point opens the fold link")
        let hit = try #require(controller.demo?.hit(p))
        #expect(controller.openLink(hit, at: p))
        #expect(recorder.folds == [Self.group])
        #expect(opened.isEmpty)
        withExtendedLifetime(window) {}
    }

    /// The first point (scan order) whose link is `url`.
    private func point(in controller: ChatController, opening url: String) -> CGPoint? {
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) {
                let p = CGPoint(x: x, y: y)
                guard controller.demo?.hit(p) != nil else { continue }
                if controller.linkURL(at: p)?.absoluteString == url { return p }
            }
        }
        return nil
    }
}
