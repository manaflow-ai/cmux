import AppKit
import Testing

@testable import CmuxWindowing

/// A fake ``ServiceFileURLReading`` returning fixed URLs regardless of the
/// pasteboard, so the resolver's orchestration is exercised without touching
/// a real pasteboard's file-URL representations.
@MainActor
private struct StubFileURLReader: ServiceFileURLReading {
    let urls: [URL]
    func fileURLs(from pasteboard: NSPasteboard) -> [URL] { urls }
}

@MainActor
@Suite("ServiceOpenPasteboardResolver")
struct ServiceOpenPasteboardResolverTests {
    private func makePasteboard(string: String?) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CmuxWindowingTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        if let string {
            pasteboard.setString(string, forType: .string)
        }
        return pasteboard
    }

    @Test("Returns the directly-carried file URLs when the reader has any")
    func returnsFileURLsWhenPresent() {
        let carried = [
            URL(fileURLWithPath: "/tmp/one"),
            URL(fileURLWithPath: "/tmp/two"),
        ]
        let resolver = ServiceOpenPasteboardResolver(
            fileURLReader: StubFileURLReader(urls: carried)
        )
        // A non-empty raw string is present but must be ignored.
        let result = resolver.pathURLs(from: makePasteboard(string: "/should/be/ignored"))
        #expect(result == carried)
    }

    @Test("Falls back to newline-split raw-string paths when no file URLs")
    func fallsBackToRawStringLines() {
        let resolver = ServiceOpenPasteboardResolver(
            fileURLReader: StubFileURLReader(urls: [])
        )
        let result = resolver.pathURLs(
            from: makePasteboard(string: "  /tmp/alpha \n/tmp/beta")
        )
        // Each line is trimmed of surrounding whitespace, then turned into a
        // file-path URL (the legacy `URL(fileURLWithPath:)` mapping).
        #expect(result.map(\.path) == ["/tmp/alpha", "/tmp/beta"])
    }

    @Test("A file: scheme line is used as-is, not re-pathed")
    func usesExplicitFileURLLine() {
        let resolver = ServiceOpenPasteboardResolver(
            fileURLReader: StubFileURLReader(urls: [])
        )
        let result = resolver.pathURLs(
            from: makePasteboard(string: "file:///tmp/gamma")
        )
        #expect(result.count == 1)
        #expect(result.first?.isFileURL == true)
        #expect(result.first?.path == "/tmp/gamma")
    }

    @Test("Empty pasteboard with no file URLs yields no paths")
    func emptyYieldsNothing() {
        let resolver = ServiceOpenPasteboardResolver(
            fileURLReader: StubFileURLReader(urls: [])
        )
        #expect(resolver.pathURLs(from: makePasteboard(string: nil)).isEmpty)
        #expect(resolver.pathURLs(from: makePasteboard(string: "")).isEmpty)
    }
}
