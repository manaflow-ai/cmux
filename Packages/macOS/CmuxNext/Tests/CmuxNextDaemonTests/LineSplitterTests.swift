import Foundation
import Testing
@testable import CmuxNextDaemon

/// The transport's line reading stays linear in the line size: a 10 MiB
/// replay (one line of about 14 MB) arrives in 256 KiB reads, and each byte
/// is searched for a newline once. Counted, not timed, so a busy machine
/// cannot fail it.
@Suite struct LineSplitterTests {
    @Test func aFullSizeReplayLineIsSearchedOnce() {
        let line = Data(#"{"event":"vt-state","data":""#.utf8)
            + Data(Data(repeating: 0x61, count: 10 << 20).base64EncodedString().utf8) + Data(#""}"#.utf8)
        let wire = line + Data([0x0A])
        var splitter = LineSplitter()
        var lines: [Data] = []
        let chunk = 256 * 1024
        var offset = 0
        while offset < wire.count {
            let end = min(offset + chunk, wire.count)
            splitter.append(wire[offset..<end]) { lines.append($0) }
            offset = end
        }
        #expect(lines.count == 1)
        #expect(lines.first == line)
        #expect(splitter.pending.isEmpty)
        #expect(splitter.scannedBytes == wire.count, "searched \(splitter.scannedBytes) bytes for \(wire.count)")
    }

    @Test func linesSplitAcrossReadsComeOutWholeAndInOrder() {
        let wire = Data("first\n\nsecond line\nthird".utf8)
        var splitter = LineSplitter()
        var lines: [String] = []
        for byte in wire { splitter.append([byte]) { lines.append(String(decoding: $0, as: UTF8.self)) } }
        #expect(lines == ["first", "second line"])
        #expect(String(decoding: splitter.pending, as: UTF8.self) == "third")
        splitter.append(Data("\n".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["first", "second line", "third"])
        #expect(splitter.scannedBytes == wire.count + 1)
    }
}
