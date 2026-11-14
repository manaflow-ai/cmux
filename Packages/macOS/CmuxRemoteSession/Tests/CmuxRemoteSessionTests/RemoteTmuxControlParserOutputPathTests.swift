import Foundation
import Testing

@testable import CmuxRemoteSession

@Suite struct RemoteTmuxControlParserOutputPathTests {
    /// After control mode is entered, `%output` takes a path of its own that skips the general
    /// line parser. It must produce exactly what the general parser does, however the transport
    /// splits the line.
    @Test func outputAfterEnterParsesLikeTheGeneralPathAtEverySplit() {
        let lines = [
            "%output %2 hi\\012\\033[1m",
            "%output %5 \\777x",
            "%output %12 plain text",
            "%output %3 ",
            "%output %7 tail\\01",
            "%output %8 \u{1b}\\kept",
            "%output %x bad",
            "%output %99999999999999999999 overflow",
            "%outputs %1 not output",
            "%window-add @4",
        ]
        for line in lines {
            var general = RemoteTmuxControlStreamParser()
            let expected = general.feed(Data((line + "\r\n").utf8))
            let stream = Data(("\u{1b}P1000p\r\n" + line + "\r\n").utf8)
            for split in 0...stream.count {
                var parser = RemoteTmuxControlStreamParser()
                var messages = parser.feed(stream.prefix(split))
                messages += parser.feed(stream.dropFirst(split))
                #expect(messages == [.enter] + expected, "\(line) split at \(split)")
            }
        }
    }
}
