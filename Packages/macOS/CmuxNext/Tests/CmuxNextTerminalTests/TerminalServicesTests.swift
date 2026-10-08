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
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-test-services-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(TerminalServices.write("ls -la", to: board, types: [.string]))
        #expect(board.string(forType: .string) == "ls -la")
        #expect(!TerminalServices.write(nil, to: board, types: [.string]))
        #expect(!TerminalServices.write("", to: board, types: [.string]))
        #expect(!TerminalServices.write("x", to: board, types: [.rtf]))
    }
}
