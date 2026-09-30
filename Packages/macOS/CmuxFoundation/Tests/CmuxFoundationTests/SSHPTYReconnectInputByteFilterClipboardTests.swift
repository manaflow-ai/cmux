import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH PTY reconnect input byte filter clipboard replies")
struct SSHPTYReconnectInputByteFilterClipboardTests {
    private static let terminators = ["\u{07}", "\u{1B}\\"]

    @Test("a stale OSC 52 clipboard reply is dropped and ordinary input passes", arguments: terminators)
    func dropsClipboardReplyBeforeOrdinaryInput(terminator: String) {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let reply = Data("\u{1B}]52;c;c2VjcmV0LXRva2Vu\(terminator)".utf8)
        let normalInput = Data("printf keep\n".utf8)

        #expect(filter.filter(reply + normalInput) == normalInput)
        #expect(!filter.isFilteringActive)
    }

    @Test("a clipboard reply split at every chunk boundary is dropped", arguments: terminators)
    func dropsClipboardReplySplitAcrossChunks(terminator: String) {
        let reply = Data("\u{1B}]52;p;c2VjcmV0\(terminator)".utf8)
        let normalInput = Data("ls\n".utf8)
        for split in 1..<reply.count {
            var filter = SSHPTYReconnectInputByteFilter(enabled: true)
            var output = filter.filter(reply.prefix(split))
            output.append(filter.filter(reply.dropFirst(split) + normalInput))

            #expect(output == normalInput, "split at \(split)")
        }
    }

    @Test("a clipboard reply larger than the pending probe bound is never forwarded")
    func dropsLargeClipboardReplyDeliveredInChunks() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let payload = String(repeating: "QUJD", count: 4096)
        let reply = Data("\u{1B}]52;c;\(payload)\u{07}".utf8)
        let normalInput = Data("echo ok\n".utf8)

        var output = Data()
        var cursor = 0
        while cursor < reply.count {
            let end = min(reply.count, cursor + 1000)
            output.append(filter.filter(reply[cursor..<end]))
            cursor = end
        }
        output.append(filter.filter(normalInput))

        #expect(output == normalInput)
    }

    @Test("stopping mid-reply does not forward the partial clipboard reply")
    func stopFilteringDropsPartialClipboardReply() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        #expect(filter.filter(Data("\u{1B}]52;c;c2VjcmV0".utf8)) == Data())
        #expect(filter.hasPendingInput)

        #expect(filter.stopFiltering() == Data())
        let normalInput = Data("ls\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)
    }

    @Test("OSC 52 bytes after filtering ends are forwarded unchanged")
    func forwardsClipboardSequenceAfterFilteringEnds() {
        var filter = SSHPTYReconnectInputByteFilter(enabled: true)
        let normalInput = Data("ls\n".utf8)
        #expect(filter.filter(normalInput) == normalInput)

        let later = Data("\u{1B}]52;c;c2VjcmV0\u{07}".utf8)
        #expect(filter.filter(later) == later)
    }
}
