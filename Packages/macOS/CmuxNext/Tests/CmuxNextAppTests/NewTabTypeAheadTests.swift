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

/// The last agent picked is remembered on this Mac (decision Q3; R86 dropped the mode).
@Suite struct NewTabChoiceMemoryTests {
    @Test func theAgentSurvivesARelaunch() throws {
        let suite = "NewTabChoiceMemoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = NewTabChoiceMemory(defaults: defaults)
        #expect(memory.agent == nil)
        memory.remember(agent: "codex")
        #expect(NewTabChoiceMemory(defaults: defaults).agent == "codex")
        // A value the page should never send is ignored.
        memory.remember(agent: "")
        #expect(NewTabChoiceMemory(defaults: defaults).agent == "codex")
    }
}
