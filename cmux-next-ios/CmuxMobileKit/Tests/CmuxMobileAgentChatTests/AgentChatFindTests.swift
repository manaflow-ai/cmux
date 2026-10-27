import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Find in Chat (the Mac's `menu.agentChat.findInChat`): every occurrence counted in prompts
/// and answers, stepped with next and previous, starting at the newest.
@MainActor
@Suite struct AgentChatFindTests {
    static func turns() -> [AgentTurn] {
        var first = AgentTurn(id: "t1", prompt: "Fix the Build", promptAt: Date(timeIntervalSince1970: 1))
        first.items = [.message(id: "a", markdown: "The build broke in `build.sh`; I fixed the build.")]
        var second = AgentTurn(id: "t2", prompt: "Résumé of what changed?", promptAt: Date(timeIntervalSince1970: 2))
        second.items = [.thought(id: "th", text: "build build build"), .message(id: "b", markdown: "Nothing else.")]
        return [first, second]
    }

    @Test func everyOccurrenceIsCountedIgnoringCaseAndAccents() {
        let blocks = AgentChatFind.blocks(of: Self.turns())
        #expect(blocks.map(\.key) == ["t1|prompt", "m-a", "t2|prompt", "m-b"])
        let build = AgentChatFind.matches(of: "BUILD", in: blocks)
        // One in the prompt, three in the answer; thoughts are not searched (they are folded).
        #expect(build.map(\.block) == ["t1|prompt", "m-a", "m-a", "m-a"])
        #expect(AgentChatFind.matches(of: "resume", in: blocks).map(\.block) == ["t2|prompt"])
        #expect(AgentChatFind.matches(of: "   ", in: blocks).isEmpty)
        #expect(AgentChatFind.matches(of: "zebra", in: blocks).isEmpty)
    }

    @Test func stepsWrapAndStartAtTheNewestMatch() {
        let find = AgentChatFind()
        find.query = "build"
        find.apply(AgentChatFind.matches(of: "build", in: AgentChatFind.blocks(of: Self.turns())), keeping: nil)
        #expect(find.countText == "4 of 4")
        let step = find.step
        find.next()
        #expect(find.countText == "1 of 4")
        #expect(find.currentBlock == "t1|prompt")
        #expect(find.step != step)
        find.previous()
        #expect(find.countText == "4 of 4")
        find.previous()
        #expect(find.countText == "3 of 4")
        #expect(find.currentBlock == "m-a")
    }

    @Test func noResultsAndAnEmptyQuerySayWhatTheyAre() {
        let find = AgentChatFind()
        #expect(find.countText == "")
        find.query = "zebra"
        find.apply([], keeping: nil)
        #expect(find.countText == "No results")
        find.next()
        #expect(find.current == nil)
    }

    @Test func newOutputKeepsTheCurrentBlock() {
        let find = AgentChatFind()
        find.query = "build"
        let blocks = AgentChatFind.blocks(of: Self.turns())
        find.apply(AgentChatFind.matches(of: "build", in: blocks), keeping: nil)
        find.next()
        #expect(find.currentBlock == "t1|prompt")
        var more = Self.turns()
        var third = AgentTurn(id: "t3", prompt: "build again", promptAt: Date(timeIntervalSince1970: 3))
        third.items = []
        more.append(third)
        find.apply(AgentChatFind.matches(of: "build", in: AgentChatFind.blocks(of: more)), keeping: find.currentBlock)
        #expect(find.currentBlock == "t1|prompt")
        #expect(find.countText == "1 of 5")
    }

    @Test func theSearchRunsOffTheMainActorAndTheNewestWins() async {
        let find = AgentChatFind()
        find.query = "build"
        find.search(Self.turns())
        find.query = "nothing"
        find.search(Self.turns())
        for _ in 0..<500 where find.countText != "1 of 1" { await Task.yield() }
        #expect(find.countText == "1 of 1")
        #expect(find.currentBlock == "m-b")
    }
}
