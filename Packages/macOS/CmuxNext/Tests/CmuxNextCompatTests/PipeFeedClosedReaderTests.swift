import CmuxNextCompat
import Foundation
import Testing

@Suite struct PipeFeedClosedReaderTests {
    /// A write after the child closed its read end must fail quietly (EPIPE), never end the
    /// process with SIGPIPE: Darwin by `F_SETNOSIGPIPE`, Linux by blocking it on the feed's thread.
    @Test func writeAfterReaderClosedDoesNotEndTheProcess() async {
        let pipe = Pipe()
        try? pipe.fileHandleForReading.close()
        let feed = PipeFeed(pipe.fileHandleForWriting)
        feed.write(Data("first".utf8))
        feed.write { fd in
            let bytes: [UInt8] = Array("second".utf8)
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            feed.write { _ in done.resume() }
        }
        feed.close()
        #expect(Bool(true))
    }
}
