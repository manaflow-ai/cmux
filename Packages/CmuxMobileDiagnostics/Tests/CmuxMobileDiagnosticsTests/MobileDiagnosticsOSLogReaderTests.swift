import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsOSLogReaderTests {
    @Test func appendRecentLineKeepsNewestEntriesAtEntryLimit() {
        var lines: [String] = []
        var bytes = 0

        #expect(!MobileDiagnosticsOSLogReader.appendRecentLine("one", to: &lines, renderedBytes: &bytes, maxEntries: 1, maxBytes: 100))
        #expect(MobileDiagnosticsOSLogReader.appendRecentLine("two", to: &lines, renderedBytes: &bytes, maxEntries: 1, maxBytes: 100))
        #expect(lines == ["two"])
    }

    @Test func appendRecentLineKeepsNewestEntriesAtByteLimit() {
        var lines: [String] = []
        var bytes = 0

        #expect(!MobileDiagnosticsOSLogReader.appendRecentLine("one", to: &lines, renderedBytes: &bytes, maxEntries: 10, maxBytes: 8))
        #expect(MobileDiagnosticsOSLogReader.appendRecentLine("three", to: &lines, renderedBytes: &bytes, maxEntries: 10, maxBytes: 8))
        #expect(lines == ["three"])
        #expect(bytes == 5)
    }

    @Test func appendRecentLineDropsOversizeLine() {
        var lines: [String] = []
        var bytes = 0

        #expect(MobileDiagnosticsOSLogReader.appendRecentLine("too-long", to: &lines, renderedBytes: &bytes, maxEntries: 10, maxBytes: 3))
        #expect(lines.isEmpty)
        #expect(bytes == 0)
    }
}
