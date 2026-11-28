@testable import CmuxNextTerminal
import Foundation
import Testing

/// A terminal records every byte it sends its program, the newest kept, for Toggle Terminal and
/// Chat's draft carry (cmux-window-rules `tabs::draft` reads them).
@Suite struct TerminalTypedTailTests {
    @Test func theSinkRecordsWhatItSendsAndAFilePasteForgetsIt() {
        let (_, continuation) = AsyncStream<TerminalOutgoing>.makeStream()
        let sink = TerminalInputSink(continuation: continuation)
        #expect(sink.typed.isEmpty)
        sink.send(Data("fix ".utf8))
        sink.send(Data("it".utf8))
        #expect(sink.typed.read.bytes == Array("fix it".utf8) && !sink.typed.read.truncated)
        // The daemon types a file paste's paths: the bytes no longer say what the input holds.
        sink.pasteFiles(TerminalFilePaste(files: ["/tmp/a.png"], image: nil))
        #expect(sink.typed.read.bytes.isEmpty && sink.typed.read.truncated && !sink.typed.isEmpty)
    }

    @Test func theNewestBytesAreKeptPastTheCap() {
        let tail = TerminalTypedTail(cap: 4)
        tail.record(Data("abc".utf8))
        #expect(tail.read.bytes == Array("abc".utf8) && !tail.read.truncated)
        tail.record(Data("def".utf8))
        #expect(tail.read.bytes == Array("cdef".utf8) && tail.read.truncated)
    }
}
