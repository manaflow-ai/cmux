import AppKit
@testable import CmuxNextTerminal
import Testing

/// cx-k9go: a terminal selection is a Services requestor for plain text
/// only. It never takes a service's result back, and it writes nothing when
/// nothing is selected.
@MainActor @Suite struct TerminalServicesTests {
    @Test func plainTextOutWithASelectionOnly() {
        #expect(TerminalServices.accepts(.string, nil, hasSelection: true))
        #expect(!TerminalServices.accepts(.string, nil, hasSelection: false))
        #expect(!TerminalServices.accepts(.string, .string, hasSelection: true), "no result is written back into the terminal")
        #expect(!TerminalServices.accepts(.fileURL, nil, hasSelection: true))
        #expect(!TerminalServices.accepts(nil, nil, hasSelection: true))
    }

    @Test func writesTheSelectionAsAString() {
        var written: [String] = []
        let set: (String) -> Bool = { written.append($0); return true }
        #expect(TerminalServices.write("ls -la", types: [.string], set: set))
        #expect(!TerminalServices.write(nil, types: [.string], set: set))
        #expect(!TerminalServices.write("", types: [.string], set: set))
        #expect(!TerminalServices.write("x", types: [.rtf], set: set))
        #expect(written == ["ls -la"])
    }
}
