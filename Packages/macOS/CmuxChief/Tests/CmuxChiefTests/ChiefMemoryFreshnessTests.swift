@testable import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// Memory edits reach a running brain session as a `<memory-update>`
/// preamble (P1-5), and the workspace summary the prompt starts with (P1-6).
@Suite struct ChiefMemoryFreshnessTests {
    let conversation = ConversationID(rawValue: "c-1")

    func state(person: String = "Austin", instructions: String = "", facts: [(String, String)] = []) -> ChiefMemoryState {
        ChiefMemoryState(person: person, instructions: instructions,
                         facts: facts.map { ChiefMemoryState.Fact(id: $0.0, text: $0.1) })
    }

    @Test func theDigestIsStableAndSeesEveryField() {
        let base = state(instructions: "Use codex --yolo.", facts: [("m-1", "Likes Zig")])
        #expect(base.digest == state(instructions: "Use codex --yolo.", facts: [("m-1", "Likes Zig")]).digest)
        #expect(base.digest != state(instructions: "Use claude.", facts: [("m-1", "Likes Zig")]).digest)
        #expect(base.digest != state(person: "Bo", instructions: "Use codex --yolo.", facts: [("m-1", "Likes Zig")]).digest)
        #expect(base.digest != state(instructions: "Use codex --yolo.", facts: []).digest)
        // Field boundaries count: moving text between fields changes the digest.
        #expect(state(person: "ab", instructions: "").digest != state(person: "a", instructions: "b").digest)
    }

    @Test func noChangeMeansNoUpdate() {
        let base = state(instructions: "Be brief.", facts: [("m-1", "Likes Zig")])
        #expect(base.update(from: base) == nil)
    }

    @Test func theUpdateNamesChangedTextAndFacts() throws {
        let old = state(instructions: "Be brief.", facts: [("m-1", "Likes Zig"), ("m-2", "Uses fish")])
        let new = state(instructions: "Be brief.\nStart agents with codex --yolo.", facts: [("m-1", "Likes Zig"), ("m-3", "Owns a cat")])
        let block = try #require(new.update(from: old))
        #expect(block.hasPrefix("<memory-update>"))
        #expect(block.hasSuffix("</memory-update>"))
        #expect(block.contains("Start agents with codex --yolo."))
        #expect(block.contains("- Owns a cat (m-3)"))
        #expect(block.contains("Forgotten facts"))
        #expect(block.contains("- Uses fish (m-2)"))
        #expect(!block.contains("person.md"))
        #expect(!block.contains("Likes Zig"))
    }

    @Test func aLargeEditIsSummarizedAsAddedAndRemovedLines() throws {
        let filler = (0..<300).map { "Rule number \($0) stays the same." }.joined(separator: "\n")
        let old = state(instructions: filler + "\nOld rule.")
        let new = state(instructions: filler + "\nNew rule.")
        let block = try #require(new.update(from: old))
        #expect(block.contains("+ New rule."))
        #expect(block.contains("- Old rule."))
        #expect(!block.contains("Rule number 7 stays"))
        #expect(block.utf8.count < ChiefMemoryState.fullTextLimitBytes + 1_024)
    }

    @Test func clearingAFileSaysSo() throws {
        let block = try #require(state(person: "").update(from: state(person: "Austin")))
        #expect(block.contains("person.md"))
        #expect(block.contains("now empty"))
    }

    @Test func freshnessTracksTheSessionBaseline() async {
        let freshness = ChiefMemoryFreshness()
        let a = state(instructions: "A")
        let b = state(instructions: "B")
        // A fresh session's prompt already holds memory.
        #expect(await freshness.preamble(for: conversation, freshSession: true, current: a) == nil)
        #expect(await freshness.preamble(for: conversation, freshSession: false, current: a) == nil)
        let update = await freshness.preamble(for: conversation, freshSession: false, current: b)
        #expect(update?.contains("B") == true)
        // Delivered once; the baseline moved.
        #expect(await freshness.preamble(for: conversation, freshSession: false, current: b) == nil)
        // A resumed session this run has not seen (after a relaunch) starts the baseline.
        let other = ConversationID(rawValue: "c-2")
        #expect(await freshness.preamble(for: other, freshSession: false, current: a) == nil)
        // A new session resets it.
        #expect(await freshness.preamble(for: conversation, freshSession: true, current: a) == nil)
    }

    @Test func theStateReadsTheMemoryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = ChiefMemory(paths: ChiefMemoryPaths(home: ChiefHome(root: root)))
        try memory.ensureDefaults()
        let before = ChiefMemoryState(memory: memory)
        #expect(before.instructions.isEmpty) // the default holds only a comment
        try "Always use worktrees.\n".write(to: memory.paths.instructions, atomically: true, encoding: .utf8)
        let fact = try memory.add("Prefers Codex", source: "cli")
        let after = ChiefMemoryState(memory: memory)
        #expect(after.instructions == "Always use worktrees.")
        #expect(after.facts == [ChiefMemoryState.Fact(id: fact.id, text: "Prefers Codex")])
        #expect(after.update(from: before)?.contains("Always use worktrees.") == true)
    }

    /// The owner prepends the preamble: editing instructions.md between two
    /// turns of one session puts the edit in the second request only.
    @Test func anInstructionsEditReachesTheNextTurnOfTheSession() async throws {
        let fixture = ChiefFixture()
        let home = fixture.home
        defer { try? FileManager.default.removeItem(at: home.root) }
        let memory = ChiefMemory(paths: ChiefMemoryPaths(home: home))
        try memory.ensureDefaults()
        let freshness = ChiefMemoryFreshness()
        let brain = FakeBrain.replying(["ok"], session: "s-1")
        let owner = try ChiefConversationOwner(home: home, brain: brain, userDisplayName: "Tester", now: { Date() }) { input in
            let preamble = await freshness.preamble(for: input.conversation, freshSession: input.resumeSession == nil,
                                                    current: ChiefMemoryState(memory: memory))
            return ChiefTurnContext(systemPrompt: "You are Chief.", workingDirectory: home.root, turnPreamble: preamble)
        }
        try await ChiefFixture.send("first", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        try await ChiefFixture.send("second", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 4)
        try "Start coding agents with codex --yolo.\n".write(to: memory.paths.instructions, atomically: true, encoding: .utf8)
        try await ChiefFixture.send("third", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 6)

        let requests = await brain.log.requests
        try #require(requests.count == 3)
        #expect(requests[0].userText == "first")
        #expect(requests[1].userText == "second")
        #expect(requests[2].resumeSession == "s-1")
        #expect(requests[2].userText.hasPrefix("<memory-update>"))
        #expect(requests[2].userText.contains("Start coding agents with codex --yolo."))
        #expect(requests[2].userText.hasSuffix("\n\nthird"))
    }

    @Test func theWorkspaceSummaryListsRefsDirectoriesAndAgents() throws {
        let lines = [
            ChiefWorkspacesSummary.Line(windowRef: "window:1", ref: "workspace:1", title: "cmux", directory: "/Users/me/src/cmux",
                                        agentState: "working", isSelected: true),
            ChiefWorkspacesSummary.Line(windowRef: "window:1", ref: "workspace:2", title: "  notes\n", directory: "/tmp",
                                        agentState: nil, isSelected: false),
            ChiefWorkspacesSummary.Line(windowRef: "window:2", ref: "workspace:3", title: "", directory: "/Users/me",
                                        agentState: "needs input", isSelected: true),
        ]
        let text = try #require(ChiefWorkspacesSummary(lines: lines, homeDirectory: "/Users/me").render())
        #expect(text == """
        - "cmux" (workspace:1, window:1, ~/src/cmux, agent: working, selected)
        - "notes" (workspace:2, window:1, /tmp)
        - "Untitled" (workspace:3, window:2, ~, agent: needs input, selected)
        For the current state run `cmux tree --all --json`.
        """)
    }

    @Test func theWorkspaceSummaryOmitsOneWindowAndCapsAtThirty() throws {
        #expect(ChiefWorkspacesSummary(lines: []).render() == nil)
        let lines = (1...32).map {
            ChiefWorkspacesSummary.Line(windowRef: "window:1", ref: "workspace:\($0)", title: "w\($0)", directory: nil,
                                        agentState: nil, isSelected: false)
        }
        let text = try #require(ChiefWorkspacesSummary(lines: lines, homeDirectory: "/Users/me").render())
        let rows = text.split(separator: "\n")
        #expect(rows.count == 32)
        #expect(rows[0] == "- \"w1\" (workspace:1)")
        #expect(rows[30] == "- (2 more workspaces not shown)")
        #expect(!text.contains("window:"))
        #expect(ChiefWorkspacesSummary.abbreviate("/Users/meow", home: "/Users/me") == "/Users/meow")
    }
}
