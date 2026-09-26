import AppKit
import Testing

@testable import CmuxTerminal

@Suite("Terminal copy-action text")
struct TerminalCopyTextTests {
    @Test("a path is copied verbatim")
    func pathIsCopiedVerbatim() {
        #expect(TerminalCopyText.payload("/Users/me/My Project") == "/Users/me/My Project")
    }

    @Test("missing, empty, and whitespace-only text has nothing to copy")
    func blankTextHasNothingToCopy() {
        #expect(TerminalCopyText.payload(nil) == nil)
        #expect(TerminalCopyText.payload("") == nil)
        #expect(TerminalCopyText.payload(" \n\t\n") == nil)
    }

    @Test("visible screen drops the blank rows under the output")
    func visibleScreenDropsTrailingBlankRows() {
        let screen = "  indented first line\n$ ls\nREADME.md\n\n\n   \n\n"
        #expect(
            TerminalCopyText.visibleScreenPayload(screen)
                == "  indented first line\n$ ls\nREADME.md"
        )
    }

    @Test("a blank visible screen has nothing to copy")
    func blankVisibleScreenHasNothingToCopy() {
        #expect(TerminalCopyText.visibleScreenPayload(nil) == nil)
        #expect(TerminalCopyText.visibleScreenPayload("\n\n    \n\n") == nil)
    }
}

@Suite("Terminal copy-action clipboard writes", .serialized)
struct TerminalCopyClipboardWriteTests {
    private func makeService() -> (TerminalPasteboardService, NSPasteboard, NSPasteboard) {
        let standard = NSPasteboard(name: .init("cmux-copy-action-\(UUID().uuidString)"))
        let selection = NSPasteboard(name: .init("cmux-copy-action-selection-\(UUID().uuidString)"))
        let service = TerminalPasteboardService(
            standardPasteboard: standard,
            selectionPasteboard: selection
        )
        return (service, standard, selection)
    }

    @Test("blank text leaves the existing clipboard untouched")
    func blankTextLeavesClipboardUntouched() {
        let (service, standard, selection) = makeService()
        defer {
            standard.releaseGlobally()
            selection.releaseGlobally()
        }
        standard.clearContents()
        standard.setString("keep me", forType: .string)
        let changeCount = standard.changeCount

        #expect(service.copyToStandardClipboard("") == false)
        #expect(service.copyToStandardClipboard("  \n") == false)
        #expect(service.copyToStandardClipboard(nil) == false)

        #expect(standard.changeCount == changeCount)
        #expect(standard.string(forType: .string) == "keep me")
    }

    @Test("non-blank text replaces the clipboard")
    func nonBlankTextReplacesClipboard() async throws {
        let (service, standard, selection) = makeService()
        defer {
            standard.releaseGlobally()
            selection.releaseGlobally()
        }
        standard.clearContents()
        standard.setString("old", forType: .string)

        #expect(service.copyToStandardClipboard("/tmp/project"))

        for _ in 0..<100 where standard.string(forType: .string) != "/tmp/project" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(standard.string(forType: .string) == "/tmp/project")
    }
}
