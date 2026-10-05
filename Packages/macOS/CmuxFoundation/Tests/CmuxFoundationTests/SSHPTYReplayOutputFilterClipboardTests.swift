import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH PTY replay output filter clipboard reads")
struct SSHPTYReplayOutputFilterClipboardTests {
    private static let selections = ["c", "p", "s", "0", "7", "", "cp", "s0"]
    private static let terminators = ["\u{07}", "\u{1B}\\"]

    @Test(
        "replayed OSC 52 clipboard reads are removed for every selection and terminator",
        arguments: selections, terminators
    )
    func stripsReplayedClipboardRead(selection: String, terminator: String) {
        let replay = Data("before\u{1B}]52;\(selection);?\(terminator)after".utf8)
        var filter = SSHPTYReplayOutputFilter(replayBytes: replay.count)

        var output = filter.filter(replay)
        output.append(filter.finish())

        #expect(String(decoding: output, as: UTF8.self) == "beforeafter")
    }

    @Test(
        "a clipboard read split at every chunk boundary is still removed",
        arguments: terminators
    )
    func stripsClipboardReadSplitAcrossChunks(terminator: String) {
        let replay = Data("before\u{1B}]52;c;?\(terminator)after".utf8)
        for split in 1..<replay.count {
            var filter = SSHPTYReplayOutputFilter(replayBytes: replay.count)
            var output = filter.filter(replay.prefix(split))
            output.append(filter.filter(replay.dropFirst(split)))
            output.append(filter.finish())

            #expect(String(decoding: output, as: UTF8.self) == "beforeafter", "split at \(split)")
        }
    }

    @Test("a clipboard read delivered one byte at a time is removed")
    func stripsClipboardReadDeliveredBytewise() {
        let replay = Data("a\u{1B}]52;p;?\u{1B}\\b\u{1B}]52;;?\u{07}c".utf8)
        var filter = SSHPTYReplayOutputFilter(replayBytes: replay.count)
        var output = Data()
        for byte in replay {
            output.append(filter.filter(Data([byte])))
        }
        output.append(filter.finish())

        #expect(String(decoding: output, as: UTF8.self) == "abc")
    }

    @Test("replayed OSC 52 clipboard writes and neighbouring output stay byte-identical")
    func preservesClipboardWrites() {
        let replay = Data([
            "before\n",
            "\u{1B}]52;c;aGVsbG8=\u{07}",
            "\u{1B}]52;s0;d29ybGQ/\u{1B}\\",
            "\u{1B}]52;c;\u{07}",
            "\u{1B}]52;c;?extra\u{07}",
            "\u{1B}]2;title?\u{07}",
            "after\n",
        ].joined().utf8)
        var filter = SSHPTYReplayOutputFilter(replayBytes: replay.count)
        var output = Data()
        for byte in replay {
            output.append(filter.filter(Data([byte])))
        }
        output.append(filter.finish())

        #expect(output == replay)
    }

    @Test("a live clipboard read after the replay boundary is forwarded unchanged")
    func preservesLiveClipboardReadAfterReplay() {
        let replay = Data("history\n".utf8)
        let live = Data("\u{1B}]52;c;?\u{07}".utf8)
        var filter = SSHPTYReplayOutputFilter(replayBytes: replay.count)

        #expect(filter.filter(replay) == replay)
        #expect(filter.filter(live) == live)
    }
}
