import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Find in Home's Chief chat (Cmd-F) as the agent chat's Find in Chat finds: every match in the loaded
/// messages, case-insensitive, the first current and on screen; Next and Previous wrap; each shown
/// row draws its matches (all of them, and the current one apart); an empty query clears them.
/// The real view over a real `HomeStore` (`HomeChatRig`).
@MainActor @Suite(.serialized) struct HomeTranscriptFindTests {
    private func rig() async throws -> HomeChatRig {
        let r = try await HomeChatRig(history: 30)
        await r.send("\(HomeChatRig.tag) the zebra crossed, then a Zebra came back")
        await r.send("\(HomeChatRig.tag) one more ZEBRA at the end")
        for _ in 0..<4 { r.frame() }
        return r
    }

    private func drawn(_ r: HomeChatRig) -> (all: Int, current: Int) {
        guard let demo = r.view.controller.demo else { return (0, 0) }
        var all = 0, current = 0
        for case let cell as RowCell in demo.collection.visibleCells {
            let paths = cell.findHighlightPaths
            if let p = paths.all, !p.isEmpty { all += 1 }
            if let p = paths.current, !p.isEmpty { current += 1 }
        }
        return (all, current)
    }

    @Test func findCountsCaseInsensitiveMatchesAndStepsThroughThem() async throws {
        let r = try await rig()
        defer { r.stop() }
        let first = r.view.find("zebra")
        #expect(first.total == 3, "three zebras, any case: \(first)")
        #expect(first.current == 1)
        #expect(r.view.find("ZEBRA").total == 3, "the query's case does not matter")
        r.frame()
        #expect(drawn(r).current == 1, "the current match is drawn once")

        #expect(r.view.findStep(forward: true).current == 2)
        #expect(r.view.findStep(forward: true).current == 3)
        #expect(r.view.findStep(forward: true).current == 1, "Next wraps to the first")
        #expect(r.view.findStep(forward: false).current == 3, "Previous wraps to the last")

        #expect(r.view.find("no such word here").total == 0)
        r.view.find("")
        r.frame()
        #expect(drawn(r).all == 0 && drawn(r).current == 0, "an empty query clears every highlight")
    }

    @Test func theCurrentMatchScrollsIntoView() async throws {
        let r = try await HomeChatRig(history: 120)
        defer { r.stop() }
        for _ in 0..<4 { r.frame() }
        // The oldest loaded text row's first word: far above the newest messages the chat opens at.
        let demo = try #require(r.view.controller.demo)
        let oldest = try #require(demo.model.rows.first { !$0.ghost && TranscriptSelection.geometry($0.spec) != nil })
        let text = try #require(TranscriptSelection.geometry(oldest.spec)).substring(NSRange(location: 0, length: 24))
        let word = try #require(text.split(separator: " ").first { $0.count >= 4 }.map(String.init))
        let before = demo.collection.contentOffset.y
        let found = r.view.find(word)
        #expect(found.total >= 1)
        r.frame()
        #expect(demo.collection.contentOffset.y != before || drawn(r).current == 1, "the first match did not scroll into view")
        #expect(drawn(r).current == 1, "the current match is not on screen")
    }
}
