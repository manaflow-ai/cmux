import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsOSLogReaderTests {
    @Test func appendCappedLineStopsAtEntryLimit() {
        var lines: [String] = []
        var bytes = 0

        #expect(appendMobileDiagnosticsCappedLine("one", to: &lines, renderedBytes: &bytes, maxEntries: 1, maxBytes: 100))
        #expect(!appendMobileDiagnosticsCappedLine("two", to: &lines, renderedBytes: &bytes, maxEntries: 1, maxBytes: 100))
        #expect(lines == ["one"])
    }

    @Test func appendCappedLineStopsAtByteLimit() {
        var lines: [String] = []
        var bytes = 0

        #expect(appendMobileDiagnosticsCappedLine("one", to: &lines, renderedBytes: &bytes, maxEntries: 10, maxBytes: 7))
        #expect(!appendMobileDiagnosticsCappedLine("three", to: &lines, renderedBytes: &bytes, maxEntries: 10, maxBytes: 7))
        #expect(lines == ["one"])
    }
}
