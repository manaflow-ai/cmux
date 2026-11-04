#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// The Mac's chat polish rows on the phone (cmux#25834): Copy rows, bookmarks and pins,
/// Previous/Next Turn, Text and Width, Read Aloud, Check and Retry Permission, the Event
/// Inspector's journal and Replay Conversation's timeline.
@MainActor
@Suite struct ChatPolishParityTests {
    final class Source: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s1", name: "S", harness: "claude", agentName: "Claude", cwd: "/w",
                                          workspaceTitle: "w", macName: "Studio", macID: "mac")
        var sent: [AgentClientIntent] = []
        var marks: [(seq: Int, on: Bool)] = []
        var refuseMarks = false
        var refreshed = 0
        var bookmarkReads = 0
        var marksOnMac: [Int]?
        var details = AgentSessionDetails(name: "fix-tests", sessionID: "acpmux-1", harnessSessionID: "h-9", cwd: "/w/proj", host: "Studio",
                                          status: AgentSessionStatus(harness: "claude", fields: []))
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
        func sessionDetails() async throws -> AgentSessionDetails { details }
        func setBookmark(seq: Int, bookmarked: Bool) async throws -> [Int] {
            marks.append((seq, bookmarked))
            if refuseMarks { throw AgentFeatureUnavailable("the chat is moving") }
            return bookmarked ? [seq] : []
        }
        func refreshPermissions() { refreshed += 1 }
        func bookmarks() async throws -> [Int] {
            bookmarkReads += 1
            guard let marksOnMac else { throw AgentFeatureUnavailable("Agents on Studio aren't connected.") }
            return marksOnMac
        }
    }

    private func turn(_ store: AgentChatStore, _ id: String, prompt: String, promptSeq: Int, resultSeq: Int, answer: String = "ok") {
        store.nextFrame = nil
        store.apply(.userMessage(text: prompt, promptId: "p-\(id)", turnId: id, attachments: [], at: Date()))
        store.apply(.promptSeq(turnId: id, seq: promptSeq))
        store.apply(.turnStarted(turnId: id, at: Date()))
        store.apply(.update(.agentMessageChunk(text: answer, messageId: "m-\(id)")))
        store.apply(.turnResult(turnId: id, status: .completed, errorText: nil, at: Date()))
        store.apply(.turnSeq(turnId: id, seq: resultSeq))
    }

    /// Waits for the store's mark call to come back (it runs in a task).
    private func settle(_ source: Source, calls: Int) async {
        for _ in 0..<200 where source.marks.count < calls { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: Copy rows

    @Test func copyRowsUseTheMacWordingAndValues() async throws {
        let source = Source()
        let store = AgentChatStore(source: source)
        turn(store, "t1", prompt: "Reply ONE", promptSeq: 3, resultSeq: 9, answer: "ONE")
        #expect(AgentChatCopy.allCases.map(\.title) == [
            "Copy Agent Name", "Copy Session ID", "Copy Harness Session ID", "Copy Conversation as Markdown",
            "Copy Session Details", "Copy Working Directory", "Copy Chat Host",
        ])
        #expect(try await AgentChatCopy.agentName.text(for: store) == "fix-tests")
        #expect(try await AgentChatCopy.sessionID.text(for: store) == "acpmux-1", "the acpmux id, never the tab's")
        #expect(try await AgentChatCopy.harnessSessionID.text(for: store) == "h-9")
        #expect(try await AgentChatCopy.workingDirectory.text(for: store) == "/w/proj")
        #expect(try await AgentChatCopy.host.text(for: store) == "Studio")
        #expect(try await AgentChatCopy.details.text(for: store) ==
            "Agent name: fix-tests\nAgent identifier: acpmux-1\nHarness session ID: h-9\nCWD: /w/proj\nHost: Studio")
        #expect(try await AgentChatCopy.conversation.text(for: store) == "**User:**\nReply ONE\n\n**Assistant:**\nONE")
        source.details.harnessSessionID = nil
        await #expect(throws: AgentFeatureUnavailable.self) { try await AgentChatCopy.harnessSessionID.text(for: store) }
    }

    @Test func conversationMarkdownListsToolTitlesOnly() {
        var turn = AgentTurn(id: "t", prompt: "", attachments: [AgentAttachment(kind: .image, name: "a.png")], promptAt: Date())
        let long = String(repeating: "word ", count: 50)
        turn.items = [.tool(ACPToolCall(id: "c", title: "Read   file.swift", kind: .read, status: .completed)),
                      .message(id: "m", markdown: "done"),
                      .tool(ACPToolCall(id: "d", title: long, kind: .read, status: .completed))]
        let text = AgentChatCopy.conversationMarkdown([turn])
        let blocks = text.components(separatedBy: "\n\n")
        #expect(blocks[0] == "**User:**\n(attachment)")
        #expect(blocks[1] == "- Tool: Read file.swift")
        #expect(blocks[2] == "**Assistant:**\ndone")
        #expect(blocks[3].count == "- Tool: ".count + 158 && blocks[3].hasSuffix("…"))
    }

    // MARK: Bookmarks and pins

    @Test func bookmarkMarksThePromptRecordAndPinTheAnswers() async {
        let source = Source()
        let store = AgentChatStore(source: source)
        turn(store, "t1", prompt: "one", promptSeq: 3, resultSeq: 9)
        let t1 = store.turns[0]
        #expect(store.canBookmark(t1) && store.canPin(t1))
        store.toggleBookmark(t1)
        #expect(store.isBookmarked(t1), "shown at once")
        await settle(source, calls: 1)
        #expect(source.marks.map(\.seq) == [3] && source.marks[0].on)
        store.togglePin(t1)
        await settle(source, calls: 2)
        #expect(source.marks.last?.seq == 9)
        // acpmux's record of every mark is what shows.
        store.apply(.bookmarks([3, 9]))
        #expect(store.isBookmarked(t1) && store.isPinned(t1))
        store.apply(.bookmarks([]))
        #expect(!store.isBookmarked(t1) && !store.isPinned(t1))
    }

    @Test func aRefusedBookmarkGoesBackAndSaysWhy() async {
        let source = Source()
        source.refuseMarks = true
        let store = AgentChatStore(source: source)
        turn(store, "t1", prompt: "one", promptSeq: 3, resultSeq: 9)
        store.toggleBookmark(store.turns[0])
        await settle(source, calls: 1)
        #expect(!store.isBookmarked(store.turns[0]))
        #expect(store.clientError == "the chat is moving")
    }

    @Test func marksAreReadAgainWhenTheChatConnects() async {
        let source = Source()
        let store = AgentChatStore(source: source)
        turn(store, "t1", prompt: "one", promptSeq: 3, resultSeq: 9)
        store.showBookmarks()
        for _ in 0..<100 { await Task.yield() }
        #expect(source.bookmarkReads == 1 && !store.isBookmarked(store.turns[0]), "the first read failed: the link was down")
        source.marksOnMac = [3]
        store.apply(.status(.ready))
        for _ in 0..<100 { await Task.yield() }
        #expect(store.isBookmarked(store.turns[0]))
        store.apply(.status(.ready))
        for _ in 0..<100 { await Task.yield() }
        #expect(source.bookmarkReads == 2, "read once it succeeded")
    }

    @Test func aReplayKeepsNoMarks() {
        let replay = ReplaySource(summary: Source().summary)
        let store = AgentChatStore(source: replay)
        turn(store, "t1", prompt: "one", promptSeq: 3, resultSeq: 9)
        #expect(!store.canBookmark(store.turns[0]) && !store.canPin(store.turns[0]))
    }

    @Test func aPromptAcpmuxHasNotLoggedCannotBeBookmarked() {
        let store = AgentChatStore(source: Source())
        store.apply(.userMessage(text: "x", promptId: "p", turnId: "t", attachments: [], at: Date()))
        #expect(!store.canBookmark(store.turns[0]))
        #expect(!store.canPin(store.turns[0]))
    }

    // MARK: Previous/Next Turn

    @Test func turnStepsStopAtTheEndsAndGoBackToAPromptAbove() {
        typealias N = ChatTurnNavigator
        #expect(N.target(count: 3, reading: (1, false), forward: true) == 2)
        #expect(N.target(count: 3, reading: (2, false), forward: true) == nil, "no wrap at the end")
        #expect(N.target(count: 3, reading: (0, false), forward: false) == nil, "no wrap at the start")
        #expect(N.target(count: 3, reading: (1, true), forward: false) == 1, "a prompt scrolled above is the previous turn")
        #expect(N.target(count: 3, reading: (1, false), forward: false) == 0)
        #expect(N.target(count: 3, reading: nil, forward: true) == 0)
        #expect(N.target(count: 0, reading: nil, forward: true) == nil)
    }

    @Test func bookmarkedOnlyStepsOverUnmarkedTurns() {
        let store = AgentChatStore(source: Source())
        turn(store, "a", prompt: "a", promptSeq: 1, resultSeq: 2)
        turn(store, "b", prompt: "b", promptSeq: 3, resultSeq: 4)
        turn(store, "c", prompt: "c", promptSeq: 5, resultSeq: 6)
        store.apply(.bookmarks([1, 5, 4]))
        #expect(store.navigableTurns(bookmarkedOnly: true).map(\.id) == ["a", "c"], "a pin is not a bookmarked prompt")
        #expect(store.navigableTurns(bookmarkedOnly: false).count == 3)
    }

    // MARK: Text and Width

    @Test func zoomStepsThroughTheTextSizesFromThePersonsOwn() {
        var settings = ChatDisplaySettings()
        #expect(settings.category(system: .large) == nil, "Actual Size draws at the person's size")
        #expect(settings.percent(system: .large) == 100)
        settings.zoomStep = 1
        #expect(settings.category(system: .large) == .extraLarge)
        #expect(settings.percent(system: .large) == 112)
        settings.zoomStep = -3
        #expect(settings.category(system: .large) == .extraSmall)
        #expect(!settings.canZoomOut(system: .large))
        settings.zoomStep = 20
        #expect(settings.category(system: .large) == .accessibilityExtraLarge, "clamped at the largest")
        #expect(!settings.canZoomIn(system: .large))
    }

    @Test func eachChatKeepsItsOwnTextAndWidth() throws {
        let defaults = try #require(UserDefaults(suiteName: "chat-display-\(UUID().uuidString)"))
        let preferences = ChatDisplayPreferences(defaults: defaults)
        let a = Source().summary
        var b = a
        b.id = "s2"
        preferences.update(a) { $0.zoomStep = 2; $0.fullWidth = false }
        #expect(preferences.settings(for: a) == ChatDisplaySettings(zoomStep: 2, fullWidth: false))
        #expect(preferences.settings(for: b) == ChatDisplaySettings())
        // Kept across launches.
        #expect(ChatDisplayPreferences(defaults: defaults).settings(for: a).zoomStep == 2)
        // Back to the defaults: nothing kept for it.
        preferences.update(a) { $0 = ChatDisplaySettings() }
        #expect(ChatDisplayPreferences(defaults: defaults).settings(for: a) == ChatDisplaySettings())
    }

    @Test func onlyTheNewestChatsKeepTheirTextAndWidth() throws {
        let defaults = try #require(UserDefaults(suiteName: "chat-display-\(UUID().uuidString)"))
        let preferences = ChatDisplayPreferences(defaults: defaults)
        var summary = Source().summary
        for index in 0...ChatDisplayPreferences.limit {
            summary.id = "chat-\(index)"
            preferences.update(summary) { $0.zoomStep = 1 }
        }
        summary.id = "chat-0"
        #expect(preferences.settings(for: summary).zoomStep == 0, "the oldest went back to the defaults")
        summary.id = "chat-\(ChatDisplayPreferences.limit)"
        #expect(preferences.settings(for: summary).zoomStep == 1)
    }

    // MARK: Read Aloud

    @Test func readAloudSpeaksTheProseNotTheMarkup() {
        let markdown = "# Title\n\nSee **bold** and `code` and [the docs](https://x.y).\n\n```swift\nlet secret = 1\n```\n- item one\n> quoted"
        #expect(ChatReadAloud.spokenText(markdown) == "Title See bold and code and the docs. item one quoted")
    }

    // MARK: Check and Retry Permission

    @Test func checkAndRetrySendsTheLostAnswerAgain() {
        let source = Source()
        let store = AgentChatStore(source: source)
        store.apply(.userMessage(text: "go", promptId: "p", turnId: "t", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t", at: Date()))
        let deny = ACPPermissionOption(id: "deny", name: "Deny", kind: .rejectOnce)
        let request = ACPPermissionRequest(id: "perm-1", toolCall: ACPToolCall(id: "c", title: "Run", kind: .execute, status: .pending),
                                           options: [deny])
        store.apply(.permissionRequest(request))
        store.respond(to: request, option: deny)
        #expect(!store.permissionAnswerUncertain)
        // The answer's reply was lost while the ask stays open.
        store.apply(.clientError("The Mac didn't answer."))
        #expect(store.permissionAnswerUncertain)
        store.checkAndRetryPermission()
        #expect(source.sent.last == .respondPermission(permissionId: "perm-1", optionId: "deny"))
        #expect(!store.permissionAnswerUncertain)
        // Decided on the Mac: nothing left to retry; a retry reads the asks again instead.
        store.apply(.permissionDecision(permissionId: "perm-1", optionId: "deny"))
        store.checkAndRetryPermission()
        #expect(source.refreshed == 1)
    }

    // MARK: Event Inspector

    @Test func theJournalKeepsTheNewest500Records() throws {
        let journal = AgentEventJournal()
        for seq in 1...(AgentEventJournal.limit + 20) {
            journal.record(.object(["seq": .number(Double(seq)), "dir": .string("in"), "kind": .string("agent_message_chunk"),
                                    "msg": .object(["method": .string("session/update"),
                                                    "params": .object(["update": .object(["sessionUpdate": .string("agent_message_chunk")])])])]))
        }
        #expect(journal.events.count == AgentEventJournal.limit)
        #expect(journal.dropped == 20)
        let newest = try #require(journal.events.last)
        #expect(newest.title == "session/update agent_message_chunk · seq \(AgentEventJournal.limit + 20)")
        #expect(newest.matches("AGENT_MESSAGE") && !newest.matches("tool_call"))
        #expect(journal.jsonLines([newest]).hasPrefix("{\"dir\":\"in\""))
        journal.clear()
        #expect(journal.events.isEmpty && journal.dropped == 0)
    }

    @Test func theJournalKeepsItsByteBudget() {
        let journal = AgentEventJournal()
        let big = String(repeating: "x", count: 200 << 10)
        for seq in 1...40 {
            journal.record(.object(["seq": .number(Double(seq)), "kind": .string("tool_call_update"), "msg": .string(big)]))
        }
        #expect(journal.events.reduce(0) { $0 + $1.line.utf8.count } <= AgentEventJournal.maxBytes)
        #expect(journal.events.last?.seq == 40 && journal.dropped > 0)
        // One record past the per-record cap keeps its kind and seq only.
        journal.record(.object(["seq": .number(41), "kind": .string("tool_call_update"), "msg": .string(big + big)]))
        #expect(journal.events.last?.kind == "tool_call_update" && journal.events.last?.seq == 41)
        #expect(journal.events.last?.line.contains("only its kind and seq") == true)
    }

    // MARK: Replay Conversation

    @Test func replayCutsLongPausesAndFindsToolCalls() {
        let start = Date(timeIntervalSince1970: 1_000)
        let event = AgentSessionEvent.status(.idle)
        let recording = AgentReplayRecording.build([
            (start, [event], false),
            (start.addingTimeInterval(1), [event], true),
            (start.addingTimeInterval(61), [event], false),
            (start.addingTimeInterval(62.5), [event], true),
            (start.addingTimeInterval(63), [], false),
        ], truncated: false)
        #expect(recording.steps.map(\.time) == [0, 1, 3, 4.5], "a minute's pause plays as 2 s; a record with no events is skipped")
        #expect(recording.duration == 4.5)
        #expect(recording.played(at: 0) == 1)
        #expect(recording.played(at: 3.2) == 3)
        #expect(recording.nextToolCall(after: 1) == 4.5)
        #expect(recording.previousToolCall(before: 4.5) == 1)
        #expect(recording.previousToolCall(before: 1.5) == nil, "within 750 ms of a call, Previous goes to the one before it")
        #expect(AgentReplayRecording.clock(75.9) == "1:15")
    }

    @Test func replayPlaysIntoItsOwnReadOnlyStore() {
        let source = ReplaySource(summary: Source().summary)
        let store = AgentChatStore(source: source)
        source.play([.userMessage(text: "hi", promptId: "p", turnId: "t", attachments: [], at: Date())])
        source.send(.cancel)
        #expect(source.summary.status == .idle)
    }
}
#endif
