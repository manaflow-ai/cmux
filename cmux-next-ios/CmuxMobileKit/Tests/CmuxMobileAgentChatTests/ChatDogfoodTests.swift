@testable import CmuxMobileAgentChat
import CmuxMobileArtifacts
import Foundation
import Testing

/// Logic fixes from the chat dogfood pass (verify/chat-dogfood.md).
@Suite struct WorkingIndicatorTests {
    private func call(_ id: String, _ status: ACPToolCall.Status, kind: ACPToolCall.Kind = .read) -> ACPToolCall {
        ACPToolCall(id: id, title: "Read \(id)", kind: kind, status: status)
    }

    @Test func showsBeforeTheFirstRowAndAfterFinishedTools() {
        #expect([TurnRow]().needsWorkingIndicator)
        #expect([TurnRow.tool(call("a", .completed))].needsWorkingIndicator)
        #expect([TurnRow.toolGroup(id: "g", calls: [call("a", .completed), call("b", .failed)])].needsWorkingIndicator)
        #expect([TurnRow.plan(id: "p", entries: [])].needsWorkingIndicator)
    }

    @Test func hiddenWhileTheLastRowShowsItsOwnProgress() {
        #expect(![TurnRow.message(id: "m", markdown: "Hi")].needsWorkingIndicator)
        #expect(![TurnRow.thought(id: "t", text: "…")].needsWorkingIndicator)
        #expect(![TurnRow.tool(call("a", .inProgress))].needsWorkingIndicator)
        #expect(![TurnRow.edit(call("e", .pending, kind: .edit))].needsWorkingIndicator)
        #expect(![TurnRow.toolGroup(id: "g", calls: [call("a", .completed), call("b", .inProgress)])].needsWorkingIndicator)
    }

    @Test func hiddenWhileWaitingOnThePerson() {
        let request = ACPPermissionRequest(id: "r", toolCall: call("x", .pending, kind: .execute), options: [])
        #expect(![TurnRow.permission(PermissionRecord(request: request))].needsWorkingIndicator)
        #expect([TurnRow.permission(PermissionRecord(request: request, resolution: .cancelled))].needsWorkingIndicator)
        #expect(![TurnRow.question("q")].needsWorkingIndicator)
    }
}

/// "Reply instead" on a permission request (SPEC 6.5): the reply denies the
/// request and is sent as guidance, so the agent is never left waiting on a
/// permission nobody can answer.
@MainActor
@Suite struct ReplyInsteadTests {
    @Test func replyDeniesThePendingPermissionAndQueuesTheGuidance() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 4000
        let store = AgentChatStore(source: mock)
        while store.turns.isEmpty { await Task.yield() }
        store.send(prompt: "go")
        while store.pendingPermission == nil { await Task.yield() }
        let request = try #require(store.pendingPermission).request
        store.send(prompt: "Run only the dialer tests instead", denyingPermission: true)
        for _ in 0..<200 where store.pendingPermission != nil { await Task.yield() }
        #expect(store.pendingPermission == nil)
        let record = store.turns.last?.items.compactMap { item -> PermissionRecord? in
            if case .permission(let record) = item, record.request.id == request.id { return record }
            return nil
        }.first
        if case .chose(let option) = record?.resolution {
            #expect(!option.isAllow)
        } else {
            Issue.record("permission not denied: \(String(describing: record?.resolution))")
        }
        for _ in 0..<200 where store.queue.isEmpty { await Task.yield() }
        #expect(store.queue.map(\.text) == ["Run only the dialer tests instead"])
    }
}

extension ReplyInsteadTests {
    /// A draft typed before the request arrived is a follow-up, not an answer.
    @Test func plainMessageQueuesAndLeavesThePermissionPending() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 4000
        let store = AgentChatStore(source: mock)
        while store.turns.isEmpty { await Task.yield() }
        store.send(prompt: "go")
        while store.pendingPermission == nil { await Task.yield() }
        store.send(prompt: "Also check the coupon")
        for _ in 0..<200 where store.queue.isEmpty { await Task.yield() }
        #expect(store.queue.map(\.text) == ["Also check the coupon"])
        #expect(store.pendingPermission != nil)
    }
}

@Suite struct ComposerMentionTests {
    @Test func findsTheMentionBeingTyped() {
        #expect(ComposerMention(text: "look at @Link")?.query == "Link")
        #expect(ComposerMention(text: "@")?.query == "")
        #expect(ComposerMention(text: "mail me@host") == nil)
        #expect(ComposerMention(text: "@done and more") == nil)
        #expect(ComposerMention(text: "code `x @y") == nil)
    }

    @Test func insertsThePathLikeTheMacComposer() throws {
        let mention = try #require(ComposerMention(text: "fix @dia"))
        #expect(mention.inserting("Sources/LinkDialer.swift", into: "fix @dia") == "fix @Sources/LinkDialer.swift ")
        #expect(ComposerMention.text(for: "My Docs/a.md") == "@\"My Docs/a.md\" ")
    }

    @Test func ranksNamePrefixFirstAndSkipsLinksAndAttachments() {
        let artifacts = [
            TerminalArtifact(reference: "Sources/Transport/LinkDialer.swift", kind: .code, order: 0),
            TerminalArtifact(reference: "docs/dialer-notes.md", kind: .markdown, order: 1),
            TerminalArtifact(reference: "dialer/README.md", kind: .markdown, order: 2),
            TerminalArtifact(reference: "https://dialer.example.com", kind: .link, order: 3),
            TerminalArtifact(reference: "Attachments/dialer.png", kind: .image, order: 4),
        ]
        #expect(ComposerMention.candidates("dial", in: artifacts).map(\.reference) == [
            "docs/dialer-notes.md", "Sources/Transport/LinkDialer.swift", "dialer/README.md",
        ])
        #expect(ComposerMention.candidates("", in: artifacts).count == 3)
    }
}

@Suite struct MenuTimestampTests {
    @Test func relativeDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 16))!
        func at(_ day: Int, _ hour: Int, month: Int = 10, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 3))!
        }
        func stamp(_ date: Date) -> String {
            AgentTurn.menuTimestamp(date, now: now, calendar: calendar, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(stamp(at(13, 15)) == "Today, 3:03 PM")
        #expect(stamp(at(12, 9)) == "Yesterday, 9:03 AM")
        #expect(stamp(at(9, 9)) == "Friday, 9:03 AM")
        #expect(stamp(at(2, 9)) == "Oct 2, 9:03 AM")
        #expect(stamp(at(2, 9, year: 2025)) == "Oct 2, 2025, 9:03 AM")
    }
}

/// Stop while the agent waits on a question or permission ends the turn.
@MainActor
@Suite struct StopWhileWaitingTests {
    @Test func stopDuringAPermissionEndsTheTurn() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 4000
        let store = AgentChatStore(source: mock)
        while store.turns.isEmpty { await Task.yield() }
        store.send(prompt: "go")
        while store.pendingPermission == nil { await Task.yield() }
        store.cancel()
        for _ in 0..<500 where store.isRunning { await Task.yield() }
        #expect(!store.isRunning)
        #expect(store.turns.last?.status == .cancelled)
    }
}

extension StopWhileWaitingTests {
    /// A question left open when its turn ends shows as cancelled, not as a live card.
    @Test func stopDuringAQuestionCancelsIt() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 4000
        let store = AgentChatStore(source: mock)
        while store.turns.isEmpty { await Task.yield() }
        store.send(prompt: "go")
        while store.pendingPermission == nil { await Task.yield() }
        let permission = try #require(store.pendingPermission)
        store.respond(to: permission.request, option: permission.request.options.first)
        while store.pendingQuestion == nil { await Task.yield() }
        let id = try #require(store.pendingQuestion).id
        store.cancel()
        for _ in 0..<500 where store.isRunning { await Task.yield() }
        #expect(store.pendingQuestion == nil)
        let question = store.turns.last?.question(id)
        #expect(question?.state == .cancelled)
    }
}

/// Round 2: a run of tool calls that grows from one call to a group kept
/// changing row identity (`c-a` to `g-a`), so the transcript crossfaded the
/// old row ("Read lib.rs") over the new one ("Read 2 files").
@Suite struct ToolRunIdentityTests {
    @Test func aRunKeepsItsRowWhileItGrows() {
        let first = ACPToolCall(id: "a", title: "Read lib.rs", kind: .read, status: .completed)
        let second = ACPToolCall(id: "b", title: "Read dial.rs", kind: .read, status: .inProgress)
        var turn = AgentTurn(id: "t", prompt: "p", promptAt: Date())
        turn.items = [.tool(first)]
        let single = turn.rows.map(\.id)
        turn.items = [.tool(first), .tool(second)]
        #expect(turn.rows.map(\.id) == single)
    }
}
