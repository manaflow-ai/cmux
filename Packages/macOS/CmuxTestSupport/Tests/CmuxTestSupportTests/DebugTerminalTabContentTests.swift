import Foundation
import Testing

@testable import CmuxTestSupport

@Suite("DebugTerminalTabContent")
struct DebugTerminalTabContentTests {
    // MARK: - Scrollback command

    @Test("Scrollback content floors at the minimum line count for a small limit")
    func scrollbackFloorsAtMinimumLineCount() {
        // A zero limit drives the byte target to the 2,000,000-byte floor.
        // baseBytesPerLine = "scrollback 000000\n".utf8.count == 18, so the
        // line count is ceil(2_000_000 / 18) == 111112, above the 2000 floor.
        let command = DebugTerminalTabContent.scrollback(scrollbackLimit: 0).text
        #expect(
            command == #"awk 'BEGIN { for (i = 1; i <= 111112; ++i) printf "scrollback %06d\n", i }'"# + "\n"
        )
    }

    @Test("Negative limit is treated as zero")
    func scrollbackNegativeLimitTreatedAsZero() {
        #expect(
            DebugTerminalTabContent.scrollback(scrollbackLimit: -5).text
                == DebugTerminalTabContent.scrollback(scrollbackLimit: 0).text
        )
    }

    @Test("Scrollback content doubles the configured limit before clamping")
    func scrollbackDoublesLimit() {
        // 50_000_000 doubled is 100_000_000, inside the [2M, 200M] clamp.
        // ceil(100_000_000 / 18) == 5555556.
        let command = DebugTerminalTabContent.scrollback(scrollbackLimit: 50_000_000).text
        #expect(
            command == #"awk 'BEGIN { for (i = 1; i <= 5555556; ++i) printf "scrollback %06d\n", i }'"# + "\n"
        )
    }

    @Test("Scrollback content clamps at the maximum byte target")
    func scrollbackClampsAtMaximum() {
        // A huge limit clamps the byte target to 200_000_000.
        // ceil(200_000_000 / 18) == 11111112.
        let command = DebugTerminalTabContent.scrollback(scrollbackLimit: 1_000_000_000).text
        #expect(
            command == #"awk 'BEGIN { for (i = 1; i <= 11111112; ++i) printf "scrollback %06d\n", i }'"# + "\n"
        )
    }

    @Test("Scrollback content is newline-terminated")
    func scrollbackNewlineTerminated() {
        #expect(DebugTerminalTabContent.scrollback(scrollbackLimit: 0).text.hasSuffix("\n"))
    }

    // MARK: - Lorem payload

    @Test("Lorem content has the expected line count and trailing newline")
    func loremShape() {
        let payload = DebugTerminalTabContent.lorem.text
        #expect(payload.hasSuffix("\n"))
        // 2000 lines joined by "\n" plus a trailing "\n" == 2000 newlines.
        let newlineCount = payload.filter { $0 == "\n" }.count
        #expect(newlineCount == DebugTerminalTabContent.loremLineCount)
    }

    @Test("Lorem content first and last lines are %04d-indexed")
    func loremIndexing() {
        let payload = DebugTerminalTabContent.lorem.text
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "0001 \(DebugTerminalTabContent.loremBaseSentence)")
        // lines is [line1, ..., line2000, ""] because of the trailing newline.
        #expect(lines[DebugTerminalTabContent.loremLineCount - 1]
            == "2000 \(DebugTerminalTabContent.loremBaseSentence)")
    }
}
