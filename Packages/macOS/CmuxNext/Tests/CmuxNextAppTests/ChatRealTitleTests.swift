import CmuxNextBridge
import Testing

/// hq#2569 #8: the title a workspace may take from its chat (`generatedTitle`) is the chat's
/// real title, never its first prompt's line, which acpmux reports as `titleSource` `prompt`
/// (or `asked` while a generated title is on its way).
struct ChatRealTitleTests {
    private static func summary(title: String?, source: String?, lastPrompt: String? = nil, name: String = "claude-sr") -> [String: Any] {
        var summary: [String: Any] = ["sessionId": "s1", "name": name, "harness": "claude-sr"]
        if let title { summary["title"] = title }
        if let source { summary["titleSource"] = source }
        if let lastPrompt { summary["lastPrompt"] = lastPrompt }
        return summary
    }

    @Test func aFirstPromptTitleIsNoRealTitle() {
        let prompt = Self.summary(title: "can you look at why the build fails", source: "prompt")
        #expect(AgentTurnStates.title(prompt, includingPrompt: false) == nil)
        #expect(AgentTurnStates.title(prompt) == "can you look at why the build fails", "the chat itself still shows its prompt until the title comes")
        let asked = Self.summary(title: "can you look at why the build fails", source: "asked")
        #expect(AgentTurnStates.title(asked, includingPrompt: false) == nil)
    }

    @Test func generatedHarnessAndAdoptedTitlesAreReal() {
        for source in ["generated", "harness", "adopted"] {
            #expect(AgentTurnStates.title(Self.summary(title: "Build Failure on Main", source: source), includingPrompt: false)
                == "Build Failure on Main", "\(source)")
        }
    }

    @Test func anOlderAcpmuxTitleIsRealUnlessTheLatestPromptStartsWithIt() {
        let fallback = Self.summary(title: "can you look at why the build fails", source: nil,
                                    lastPrompt: "can you look at   why the build fails\nit broke on main")
        #expect(AgentTurnStates.title(fallback, includingPrompt: false) == nil)
        let cut = Self.summary(title: String(repeating: "a", count: 80) + "…", source: nil, lastPrompt: String(repeating: "a", count: 120))
        #expect(AgentTurnStates.title(cut, includingPrompt: false) == nil)
        let real = Self.summary(title: "Build Failure on Main", source: nil, lastPrompt: "can you look at why the build fails")
        #expect(AgentTurnStates.title(real, includingPrompt: false) == "Build Failure on Main")
    }

    @Test func aChangeCarriesTheRealTitleOnlyOnceItArrives() {
        let before = AgentTurnStates.change(["sessionId": "s1", "session": Self.summary(title: "fix the flaky upload test", source: "asked")])
        #expect(before?.title == "fix the flaky upload test")
        #expect(before?.generatedTitle == nil)
        let after = AgentTurnStates.change(["sessionId": "s1", "session": Self.summary(title: "Flaky Upload Test Fix", source: "generated")])
        #expect(after?.generatedTitle == "Flaky Upload Test Fix")
    }

    @Test func theUsersChatNameIsNeverTheWorkspacesTitle() {
        // The tab's own user name reaches the workspace through `Front.chat(userName:)`, not here.
        let named = Self.summary(title: "Flaky Upload Test Fix", source: "generated", name: "Release notes")
        #expect(AgentTurnStates.title(named) == "Release notes")
        #expect(AgentTurnStates.title(named, includingPrompt: false) == "Flaky Upload Test Fix")
    }
}
