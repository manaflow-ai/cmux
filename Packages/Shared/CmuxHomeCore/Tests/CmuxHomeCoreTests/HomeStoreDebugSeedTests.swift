#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// The bench seed of a Home transcript (`HomeStore.debugSeed`): N rows in the store's loaded
/// window, in a fixed mix of the four kinds a pane-resize film must lay out again (text, a code
/// fence, a tool row, an image), the same in every run. The mock Chief holds 300 messages and an
/// open loads its newest 60, so a seed must replace a loaded tail it does not join.
@MainActor
@Suite struct HomeStoreDebugSeedTests {
    let id = ConversationID("conv_chief")

    enum Kind: Hashable {
        case text, code, tool, image
    }

    /// A store over the mock owner with the Chief's transcript on screen (its real tail is loaded).
    func opened() async -> HomeStore {
        let store = await started()
        await store.open(id)
        return store
    }

    func started() async -> HomeStore {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        return store
    }

    /// What a row holds, as a renderer tells the kinds apart: a work part, an image attachment,
    /// or text with or without a code fence. Nil for anything else.
    func kind(of item: TranscriptItem) -> Kind? {
        guard item.parts.count == 1, let part = item.parts.first else { return nil }
        switch part {
        case .work: return .tool
        case .attachment(let ref): return ref.mimeType.hasPrefix("image/") ? .image : nil
        case .text(let text, _): return text.contains("```") ? .code : .text
        default: return nil
        }
    }

    /// The lines between a row's opening and closing code fence; nil when it has no fenced block.
    func fencedLines(_ item: TranscriptItem) -> Int? {
        let lines = item.plainText.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.hasPrefix("```") }),
              let close = lines.lastIndex(where: { $0.hasPrefix("```") }), close > open else { return nil }
        return close - open - 1
    }

    @Test(arguments: [50, 500, 5000])
    func aSeedShowsItsRowsAndNothingOlder(rows: Int) async {
        let store = await opened()
        let seeded = await store.debugSeed(id, rows: rows)
        #expect(seeded, "the seed did not apply")
        let items = store.transcript(for: id)
        #expect(items.count == rows)
        let seqs = items.compactMap(\.seq)
        let inOrder = seqs.count == rows && seqs.enumerated().allSatisfy { $0.element == Seq($0.offset + 1) }
        #expect(inOrder, "the rows are not committed messages seq 1...\(rows)")
        #expect(items.allSatisfy { $0.delivery == .committed })
        #expect(!store.mirror.isStale(.conversation(id)), "the seed left the conversation waiting for a refetch")

        // The window starts at seq 1: a scroll to the top asks the owner for nothing.
        #expect(!store.hasOlderMessages(in: id))
        await store.loadOlder(id)
        #expect(store.transcript(for: id).count == rows, "a scroll to the top put the owner's history in the seed")
        store.stop()
    }

    /// Of every 10 rows: 6 text, 2 with a code fence, 1 tool row, 1 image. So 50 rows hold
    /// 30 / 10 / 5 / 5, 500 rows 300 / 100 / 50 / 50 and 5000 rows 3000 / 1000 / 500 / 500.
    @Test(arguments: [50, 500, 5000])
    func aSeedHasTheStatedCountOfEachKind(rows: Int) async {
        let store = await opened()
        await store.debugSeed(id, rows: rows)
        var counts: [Kind: Int] = [:]
        for item in store.transcript(for: id) {
            if let found = kind(of: item) { counts[found, default: 0] += 1 }
        }
        #expect(counts[.text] == rows * 6 / 10)
        #expect(counts[.code] == rows * 2 / 10)
        #expect(counts[.tool] == rows / 10)
        #expect(counts[.image] == rows / 10)
        // The route's answer names the same counts.
        #expect(HomeStore.debugSeedKinds(rows: rows)
            == ["text": rows * 6 / 10, "code": rows * 2 / 10, "tool": rows / 10, "image": rows / 10])
        store.stop()
    }

    /// The kind of a row depends on its index alone: every 10th row is mine and short, rows 3 and
    /// 7 of each 10 carry a fenced block of 12 lines, row 5 is a tool row with words to show, row 9
    /// is an image, and the Chief's other rows are 1 to 6 lines of text.
    @Test func theRowMixIsFixedByIndex() async throws {
        let store = await opened()
        await store.debugSeed(id, rows: 500)
        let items = store.transcript(for: id)
        try #require(items.count == 500)
        let me = try #require(store.me?.id)
        var chiefLineCounts: Set<Int> = []
        for (index, item) in items.enumerated() {
            let expected: Kind = switch index % 10 {
            case 3, 7: .code
            case 5: .tool
            case 9: .image
            default: .text
            }
            #expect(kind(of: item) == expected, "row \(index)")
            #expect((item.author == me) == (index % 10 == 0), "row \(index) has the wrong author")
            switch expected {
            case .code:
                #expect(fencedLines(item) == 12, "row \(index)")
            case .tool:
                if case .some(.work(let work)) = item.parts.first {
                    #expect(work.shownText != nil, "row \(index) is a tool row that draws nothing")
                }
            case .text:
                let lines = item.plainText.components(separatedBy: "\n").count
                if item.author == me {
                    #expect(lines == 1, "row \(index)")
                } else {
                    chiefLineCounts.insert(lines)
                }
            case .image:
                break
            }
        }
        #expect(chiefLineCounts == Set(1 ... 6), "the Chief's text rows are not 1 to 6 lines")
        store.stop()
    }

    @Test(arguments: [50, 500, 5000])
    func twoSeedsOfTheSameSizeAreEqual(rows: Int) async {
        let first = await opened()
        let second = await opened()
        await first.debugSeed(id, rows: rows)
        await second.debugSeed(id, rows: rows)
        let items = first.transcript(for: id)
        #expect(items.count == rows)
        let sameInAnotherStore = items == second.transcript(for: id)
        #expect(sameInAnotherStore, "two stores seeded with \(rows) rows show different items")
        // The same store, seeded again.
        await first.debugSeed(id, rows: rows)
        let sameAgain = items == first.transcript(for: id)
        #expect(sameAgain, "a second seed of \(rows) rows changed the items")
        first.stop()
        second.stop()
    }

    /// A seed replaces what the window held: 50 rows after 500 are 50 rows, not a window with a hole.
    @Test func aSmallerSeedReplacesALargerOne() async {
        let store = await opened()
        await store.debugSeed(id, rows: 500)
        let seeded = await store.debugSeed(id, rows: 50)
        #expect(seeded, "the smaller seed did not apply")
        #expect(store.transcript(for: id).count == 50)
        #expect(!store.hasOlderMessages(in: id))
        #expect(!store.mirror.isStale(.conversation(id)))
        store.stop()
    }

    /// Each image row shows the one prepared file the caller names.
    @Test func imageRowsShowTheGivenFile() async {
        let store = await opened()
        let image = AttachmentRef(hash: "seed-test-hash", name: "Harbor at dusk.png", mimeType: "image/png",
                                  byteCount: 9, width: 1200, height: 900)
        await store.debugSeed(id, rows: 50, image: image)
        let refs = store.transcript(for: id).flatMap(\.parts).compactMap { part -> AttachmentRef? in
            if case .attachment(let ref) = part { return ref }
            return nil
        }
        #expect(refs == Array(repeating: image, count: 5))
        store.stop()
    }

    /// A transcript shown nowhere gets no window (only a close ends what an open set up), and a
    /// size that is not 50, 500 or 5000 seeds nothing.
    @Test func aRefusedSeedChangesNothing() async {
        let closed = await started()
        let seededClosed = await closed.debugSeed(id, rows: 50)
        #expect(!seededClosed)
        #expect(closed.mirror.windows[id] == nil)
        closed.stop()

        let store = await opened()
        let before = store.transcript(for: id)
        let seededOtherSize = await store.debugSeed(id, rows: 51)
        #expect(!seededOtherSize)
        let unchanged = before == store.transcript(for: id)
        #expect(unchanged)
        store.stop()
    }
}
#endif
