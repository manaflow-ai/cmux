import Foundation
import Testing
import CmuxMobileTerminalKit

@Suite("Terminal replay query filter")
struct TerminalReplayQueryFilterTests {
    @Test("reported terminal queries are removed without changing visible replay text")
    func stripsTerminalQueriesFromReplay() {
        let replay = Data(
            (
                "before\n" +
                "\u{1B}[>q" +
                "\u{1B}[c" +
                "\u{1B}[?2026$p" +
                "\u{1B}]11;?\u{07}" +
                "\u{1B}P+q544e" + "\u{1B}\\" +
                "after\n"
            ).utf8
        )
        var filter = TerminalReplayQueryFilter(replayBytes: replay.count)
        var output = Data()
        for byte in replay {
            output.append(filter.filter(Data([byte])))
        }

        #expect(String(decoding: output, as: UTF8.self) == "before\nafter\n")
    }

    @Test("all supported Ghostty query families are removed from replay")
    func stripsAdditionalGhosttyQueryFamilies() {
        let replay = Data(
            (
                "before" +
                "\u{1B}Z" +
                "\u{1B}[14t" +
                "\u{1B}[?6n" +
                "\u{1B}[?u" +
                "\u{1B}P$qm\u{1B}\\" +
                "\u{1B}_Ga=q,i=1;\u{1B}\\" +
                "after"
            ).utf8
        )
        var filter = TerminalReplayQueryFilter(replayBytes: replay.count)

        #expect(filter.filter(replay) == Data("beforeafter".utf8))
    }

    @Test("additional XTWINOPS report queries are removed")
    func stripsAdditionalXTWINOPSReports() {
        let reportValues = [11, 13, 15, 19, 20]
        let replay = Data(
            ("before" + reportValues.map { "\u{1B}[\($0)t" }.joined() + "after").utf8
        )
        var filter = TerminalReplayQueryFilter(replayBytes: replay.count)

        #expect(filter.filter(replay) == Data("beforeafter".utf8))
    }

    @Test("live terminal negotiation after replay remains byte-for-byte")
    func preservesLiveQueriesAfterReplayBoundary() {
        let replay = Data("replay\n\u{1B}[>q".utf8)
        let live = Data("\u{1B}[>q\u{1B}[c".utf8)
        var filter = TerminalReplayQueryFilter(replayBytes: replay.count)

        let replayOutput = filter.filter(replay)
        let liveOutput = filter.filter(live)

        #expect(String(decoding: replayOutput, as: UTF8.self) == "replay\n")
        #expect(liveOutput == live)
    }

    @Test("a query split at the replay boundary is still removed")
    func stripsQueryThatCrossesReplayBoundary() {
        let replayPrefix = Data("replay\n\u{1B}[>".utf8)
        let queryTailAndLive = Data("q\u{1B}[cLIVE".utf8)
        var filter = TerminalReplayQueryFilter(replayBytes: replayPrefix.count + 1)

        let first = filter.filter(replayPrefix)
        let second = filter.filter(queryTailAndLive)

        #expect(first == Data("replay\n".utf8))
        #expect(second == Data("\u{1B}[cLIVE".utf8))
    }

    @Test("non-query terminal controls remain in replay")
    func preservesNonQueryControls() {
        let replay = Data("\u{1B}[31mred\u{1B}]0;title\u{07}\n".utf8)
        var filter = TerminalReplayQueryFilter(replayBytes: replay.count)

        #expect(filter.filter(replay) == replay)
    }

    /// The queries tmux sends when a client attaches, then a draw: replay
    /// keeps the draw and drops every request.
    @Test("tmux attach queries are removed from a whole replay buffer")
    func stripsTmuxAttachQueries() {
        let replay = Data((
            "\u{1B}[?1049h\u{1B}[22;0;0t\u{1B}[?996n\u{1B}[c\u{1B}[>c\u{1B}[>q" +
            "\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\\u{1B}[18t\u{1B}[14t" +
            "\u{1B}[6n\u{1B}[5n\u{1B}[?2004$p\u{1B}[2004$p\u{1B}]4;1;?\u{07}\u{1B}P$q\"q\u{1B}\\" +
            "[cmux-1] 0:zsh*"
        ).utf8)
        let output = String(decoding: TerminalReplayQueryFilter.removingQueryRequests(replay), as: UTF8.self)
        #expect(output == "\u{1B}[?1049h\u{1B}[22;0;0t[cmux-1] 0:zsh*")
    }

    @Test("an unterminated trailing query is kept, not dropped")
    func keepsUnterminatedTail() {
        let replay = Data("text\u{1B}]11;".utf8)
        #expect(TerminalReplayQueryFilter.removingQueryRequests(replay) == replay)
    }
}
