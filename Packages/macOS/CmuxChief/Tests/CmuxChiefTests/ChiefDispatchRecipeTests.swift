@testable import CmuxChief
import Foundation
import Testing

/// The prompt's dispatch recipe against the tool policy: sending an agent is
/// one simple command, so it raises exactly one approval card, and an Always
/// Allow rule for `cmux chief dispatch` lets later dispatches run at once.
@Suite struct ChiefDispatchRecipeTests {
    @Test func thePromptTeachesTheDispatchVerbAndNoShellFileWrites() {
        let section = ChiefSystemPrompt.codingAgents
        #expect(section.contains(ChiefSystemPrompt.dispatchExample))
        #expect(section.contains("cmux chief dispatch --agent codex|claude"))
        for retired in ["mktemp", "<<'EOF'", "$(cat", "--command \"codex"] {
            #expect(!section.contains(retired), "the recipe still teaches \(retired)")
        }
    }

    @Test func theExampleIsOneSimpleCommandThatAsksOnce() throws {
        let stages = try #require(ChiefShellLexer.stages(of: ChiefSystemPrompt.dispatchExample))
        // One stage: one tool call, one card. Nothing chained, nothing expanded.
        #expect(stages.count == 1)
        let words = stages[0]
        #expect(!words.contains(where: { $0.expands }))
        #expect(Array(words.prefix(3).map(\.text)) == ["cmux", "chief", "dispatch"])
        // The task reaches the CLI as a single word after `--`.
        let texts = words.map(\.text)
        let separator = try #require(texts.firstIndex(of: "--"))
        #expect(texts.count == separator + 2)
        #expect(texts.last?.hasPrefix("Fix the login bug") == true)
        // Dispatch runs a coding agent, so it is never silently allowed by the built-in list.
        #expect(!ChiefToolPolicy.autoAllowsSimpleCommand(texts))
    }

    @Test func alwaysAllowCoversTheRecipeButNoOtherChiefVerb() throws {
        let rules = ChiefAllowRules()
        let stages = try #require(ChiefShellLexer.stages(of: ChiefSystemPrompt.dispatchExample))
        let words = stages[0].map(\.text)
        #expect(ChiefAllowRules.ruleWords(words) == ["cmux", "chief", "dispatch"])
        #expect(try rules.add(command: "cmux chief dispatch --agent codex") == ["cmux", "chief", "dispatch"])
        #expect(rules.allows(words))
        #expect(!rules.allows(["cmux", "chief", "approve"]))
        #expect(!rules.allows(["cmux", "chief", "send", "hi"]))
    }

    /// The card offers Always Allow for the real recipe (quotes, `#`, a long task): the policy
    /// derives the rule once from the lexed, untruncated command and carries it in the options.
    @Test func theRecipesCardOffersAlwaysAllowForDispatch() throws {
        let options = ChiefToolPolicy.approvalOptions(command: ChiefSystemPrompt.dispatchExample)
        #expect(options == ["Allow", "Deny", "always:cmux chief dispatch"])
        #expect(ChiefAllowRules.rule(inOptions: options) == ["cmux", "chief", "dispatch"])
        // A task longer than the prompt's 300 characters still gets the rule (the prompt is cut).
        let long = "cmux chief dispatch --agent claude --name \"#9: docs\" --cwd /tmp/app -- '" + String(repeating: "Fix it. ", count: 60) + "'"
        #expect(ChiefToolPolicy.claudePrompt("Bash", input: ["command": .string(long)]).hasSuffix("…`?"))
        #expect(ChiefToolPolicy.approvalOptions(command: long).last == "always:cmux chief dispatch")
        // Wrapped by Codex, the same rule.
        #expect(ChiefToolPolicy.approvalOptions(command: "/bin/zsh -lc \"cmux chief dispatch --name x -- 'y'\"").last
            == "always:cmux chief dispatch")
        // No rule for a command none may cover, nor a forged or ineligible option.
        #expect(ChiefToolPolicy.approvalOptions(command: "cmux chief approve") == ["Allow", "Deny"])
        #expect(ChiefToolPolicy.approvalOptions(command: nil) == ["Allow", "Deny"])
        #expect(ChiefAllowRules.rule(inOptions: ["Allow", "always:bash -c"]) == nil)
        #expect(ChiefAllowRules.rule(inOptions: ["Allow", "always:cmux chief"]) == nil)
    }

    @Test func aTaskWithAnApostropheStaysOneWord() throws {
        let command = #"cmux chief dispatch --agent claude --name docs --cwd /tmp/app -- 'Fix the README'\''s install steps.'"#
        let stages = try #require(ChiefShellLexer.stages(of: command))
        #expect(stages.count == 1)
        #expect(stages[0].last?.text == "Fix the README's install steps.")
        #expect(!stages[0].contains(where: { $0.expands }))
    }
}
