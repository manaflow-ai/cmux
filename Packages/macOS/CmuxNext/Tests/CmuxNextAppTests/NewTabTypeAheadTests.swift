import Foundation
import Testing
@testable import CmuxNextApp

/// `!` on the new tab screen (plans/cmux-next/new-tab.md section 3.2): what
/// the user types while the terminal is being made reaches its prompt in
/// order, edits included, and nothing is typed twice.
@Suite struct NewTabTypeAheadTests {
    @Test func theDeltaTypesOnlyWhatIsNewAndErasesWhatWasTakenBack() {
        #expect(NewTabTypeAhead.delta(sent: "", typed: "") == "")
        #expect(NewTabTypeAhead.delta(sent: "", typed: "git") == "git")
        #expect(NewTabTypeAhead.delta(sent: "git", typed: "git status") == " status")
        #expect(NewTabTypeAhead.delta(sent: "git status", typed: "git status") == "")
        // Backspace in the field while the terminal was starting: erase, then type.
        #expect(NewTabTypeAhead.delta(sent: "git stat", typed: "git log") == "\u{7f}\u{7f}\u{7f}\u{7f}log")
        #expect(NewTabTypeAhead.delta(sent: "ls", typed: "") == "\u{7f}\u{7f}")
        // Characters, not code units: an emoji is one erase.
        #expect(NewTabTypeAhead.delta(sent: "echo 👍", typed: "echo ") == "\u{7f}")
    }

    @Test func theStoreKeepsTheLatestTextPerPageUntilForgotten() {
        let store = NewTabTypeAhead()
        #expect(store.latest("page-1") == "")
        store.update("page-1", text: "gi")
        store.update("page-1", text: "git")
        store.update("page-2", text: "ls")
        #expect(store.latest("page-1") == "git")
        store.forget("page-1")
        #expect(store.latest("page-1") == "")
        #expect(store.latest("page-2") == "ls")
    }

    /// The terminal gets the text that existed when it was made, then any
    /// text typed while that was sent, until nothing new arrived.
    @Test func typingDrainsEverythingTypedBeforeThePageCloses() async throws {
        let store = NewTabTypeAhead()
        store.update("p", text: "gi")
        var sent: [String] = []
        try await store.drain("p") { text in
            sent.append(text)
            if sent.count == 1 { store.update("p", text: "git st") }
        }
        #expect(sent == ["gi", "t st"])
        #expect(store.latest("p") == "")
    }
}

/// Search | Ask and the last agent are remembered on this Mac (decision Q3).
@Suite struct NewTabChoiceMemoryTests {
    @Test func modeAndAgentSurviveARelaunch() throws {
        let suite = "NewTabChoiceMemoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        #expect(memory.mode == nil)
        #expect(memory.agent == nil)
        memory.remember(mode: "search", agent: nil)
        memory.remember(mode: nil, agent: "codex")
        let relaunched = NewTabChoiceMemory(defaults: defaults)
        #expect(relaunched.mode == .search)
        #expect(relaunched.agent == "codex")
        relaunched.remember(mode: "ask", agent: nil)
        #expect(NewTabChoiceMemory(defaults: defaults).mode == .ask)
        // A value the page should never send is ignored.
        relaunched.remember(mode: "loud", agent: "")
        #expect(NewTabChoiceMemory(defaults: defaults).mode == .ask)
        #expect(NewTabChoiceMemory(defaults: defaults).agent == "codex")
    }
}
