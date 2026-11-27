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
        #expect(blocks.map(\.key) == ["t1|prompt", "m-a|0", "t2|prompt", "m-b|0"])
        let build = AgentChatFind.matches(of: "BUILD", in: blocks)
        // One in the prompt, three in the answer; thoughts are not searched (they are folded).
        #expect(build.map(\.block) == ["t1|prompt", "m-a|0", "m-a|0", "m-a|0"])
        #expect(AgentChatFind.matches(of: "resume", in: blocks).map(\.block) == ["t2|prompt"])
        #expect(AgentChatFind.matches(of: "   ", in: blocks).isEmpty)
        #expect(AgentChatFind.matches(of: "zebra", in: blocks).isEmpty)
    }

    @Test func stepsWrapAndStartAtTheNewestMatch() {
        let find = AgentChatFind()
        find.query = "build"
        find.apply(AgentChatFind.matches(of: "build", in: AgentChatFind.blocks(of: Self.turns())), keeping: nil, reveal: true)
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
        #expect(find.currentBlock == "m-a|0")
    }

    @Test func noResultsAndAnEmptyQuerySayWhatTheyAre() {
        let find = AgentChatFind()
        #expect(find.countText == "")
        find.query = "zebra"
        find.apply([], keeping: nil, reveal: true)
        #expect(find.countText == "No results")
        find.next()
        #expect(find.current == nil)
    }

    @Test func newOutputKeepsTheCurrentMatchAndDoesNotScroll() async {
        let find = AgentChatFind()
        find.query = "build"
        find.search(Self.turns())
        await find.pending?.value
        find.next()
        find.next()
        #expect(find.countText == "2 of 4")
        #expect(find.currentBlock == "m-a|0")
        let step = find.step
        var more = Self.turns()
        more.append(AgentTurn(id: "t3", prompt: "build again", promptAt: Date(timeIntervalSince1970: 3)))
        find.refresh(more)
        await find.pending?.value
        // The same occurrence (the first in m-a), the count grown, and no scroll.
        #expect(find.countText == "2 of 5")
        #expect(find.currentBlock == "m-a|0")
        #expect(find.step == step)
    }

    @Test func streamedTextIsSearchedAsItArrives() async {
        // A chunk replaces the last message's text: no new turn, item or status.
        var turns = Self.turns()
        let before = AgentChatFind.revision(of: turns)
        turns[1].items[1] = .message(id: "b", markdown: "Nothing else. The build")
        let after = AgentChatFind.revision(of: turns)
        #expect(after != before)
        #expect(AgentChatFind.revision(of: turns) == after)

        let find = AgentChatFind()
        find.query = "build"
        find.search(Self.turns())
        await find.pending?.value
        #expect(find.countText == "4 of 4")
        find.refresh(turns)
        await find.pending?.value
        #expect(find.matches.count == 5)
        #expect(find.matches.last?.block.hasPrefix("m-b") == true)
    }

    @Test func chunksWhileARefreshRunsCollapseIntoOneSearchOfTheNewest() async {
        let find = AgentChatFind()
        find.query = "build"
        find.search(Self.turns())
        await find.pending?.value
        var turns = Self.turns()
        for text in ["build", "build build", "build build build"] {
            turns[1].items[1] = .message(id: "b", markdown: text)
            find.refresh(turns)
        }
        let first = find.pending
        await first?.value
        // The first refresh ran; the two after it became one run of the newest transcript.
        #expect(find.pending != nil)
        await find.pending?.value
        #expect(find.matches.count == 7)
    }

    @Test func outputWhileANewQueryRunsNeverLosesItsReveal() async {
        let find = AgentChatFind()
        find.query = "build"
        let step = find.step
        find.search(Self.turns())
        var turns = Self.turns()
        turns[1].items[1] = .message(id: "b", markdown: "build")
        find.refresh(turns)
        let first = find.pending
        await first?.value
        // The query's search landed and moved to its match (the newest); the output is searched
        // after it (it may have landed already) and keeps that match.
        #expect(find.step != step)
        #expect(find.currentBlock == "m-a|0")
        await find.pending?.value
        #expect(find.matches.count == 5)
        #expect(find.countText == "4 of 5")
    }

    @Test func aStepTakenWhileARefreshRunsStays() async {
        let find = AgentChatFind()
        find.query = "build"
        find.search(Self.turns())
        await find.pending?.value
        var turns = Self.turns()
        turns[1].items[1] = .message(id: "b", markdown: "build")
        find.refresh(turns)
        // Next, before the refresh lands: to the first match (the prompt).
        find.next()
        await find.pending?.value
        #expect(find.countText == "1 of 5")
        #expect(find.currentBlock == "t1|prompt")
    }

    @Test func aMatchNamesTheRenderedBlockThatHoldsIt() {
        // A long answer: the match in its last paragraph scrolls to that paragraph, not to a
        // share of the whole message (a code card and a table above it draw taller than their text).
        var turn = AgentTurn(id: "t1", prompt: "Explain", promptAt: Date(timeIntervalSince1970: 1))
        turn.items = [.message(id: "a", markdown: """
        # Summary

        ```swift
        let a = 1
        let b = 2
        ```

        | col | other |
        | --- | ----- |
        | x   | y     |

        - one
        - two kiwi

        The kiwi is here.
        """)]
        let blocks = AgentChatFind.blocks(of: [turn])
        #expect(blocks.map(\.key) == ["t1|prompt", "m-a|0", "m-a|1", "m-a|2", "m-a|3", "m-a|4"])
        #expect(blocks[2].text == "let a = 1\nlet b = 2")
        let found = AgentChatFind.matches(of: "kiwi", in: blocks)
        #expect(found.map(\.block) == ["m-a|3", "m-a|4"])
        #expect(found[1].position > 0.2)
        #expect(AgentChatFind.matches(of: "other", in: blocks).map(\.block) == ["m-a|2"])
    }

    @Test func aMatchKnowsWhereInItsBlockItIs() {
        let blocks = [AgentChatFind.Block(key: "b", text: "kiwi " + String(repeating: "x", count: 90) + " kiwi")]
        let found = AgentChatFind.matches(of: "kiwi", in: blocks)
        #expect(found.count == 2)
        #expect(found[0].position == 0)
        #expect(found[1].position > 0.9)
    }

    @Test func theSearchRunsOffTheMainActorAndTheNewestWins() async {
        let find = AgentChatFind()
        find.query = "build"
        find.search(Self.turns())
        find.query = "nothing"
        find.search(Self.turns())
        await find.pending?.value
        #expect(find.countText == "1 of 1")
        #expect(find.currentBlock == "m-b|0")
    }
}

#if os(iOS)
import UIKit

/// The row holding Find in Chat's current match reads as selected to VoiceOver (the SwiftUI
/// transcript's find marks did): its text elements get `.selected`, and lose it when the
/// match moves; its buttons are left alone.
@MainActor
@Suite struct FindMarkAccessibilityTests {
    @Test func theMarkedRowsTextReadsAsSelected() {
        let cell = UICollectionViewCell()
        let text = UIAccessibilityElement(accessibilityContainer: cell)
        text.accessibilityTraits = .staticText
        let more = UIAccessibilityElement(accessibilityContainer: cell)
        more.accessibilityTraits = .button
        cell.accessibilityElements = [text, more]

        cell.setFindMarked(true)
        #expect(text.accessibilityTraits.contains(.selected))
        #expect(!more.accessibilityTraits.contains(.selected))

        cell.setFindMarked(false)
        #expect(!text.accessibilityTraits.contains(.selected))
        #expect(text.accessibilityTraits.contains(.staticText))
    }
}
#endif
