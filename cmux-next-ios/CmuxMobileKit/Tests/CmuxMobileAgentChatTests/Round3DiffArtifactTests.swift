import CmuxMobileDiff
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileAgentChat
@testable import CmuxMobileArtifacts

/// Parity round 3: Agent Edits keeps each snippet edit apart (the Mac's Last turn view) instead
/// of diffing the first edit's old snippet against the last edit's new one; a file written then
/// edited shows as written; SVG previews as markup; a stalled file read gives up.
@Suite struct Round3DiffArtifactTests {
    @Test func snippetEditsStayApartWithoutLineNumbers() {
        let file = DiffFile(path: "a.swift", edits: [("let a = 1", "let a = 2"), ("func b() {}", "func b() { c() }")])
        #expect(file.status == .modified && !file.hasFullContext)
        #expect(file.lines.filter(\.isGap).count == 1)
        #expect(file.lines.filter { $0.kind == .removed }.map(\.text) == ["let a = 1", "func b() {}"])
        #expect(file.lines.filter { $0.kind == .added }.map(\.text) == ["let a = 2", "func b() { c() }"])
        // Where a snippet sits in the file is unknown: no line numbers.
        #expect(file.lines.allSatisfy { $0.oldNumber == nil && $0.newNumber == nil })
    }

    @Test func aWrittenFileTakesItsLaterEdits() {
        let file = DiffFile(path: "new.txt", edits: [(nil, "one\ntwo\nthree\n"), ("two", "TWO")])
        #expect(file.status == .added && file.hasFullContext)
        #expect(file.lines.map(\.text) == ["one", "TWO", "three"])
        #expect(file.lines.last?.newNumber == 3)
    }

    @Test func turnEditsSkipPendingAndRefusedCalls() throws {
        func call(_ id: String, _ status: String) throws -> ACPToolCall {
            try JSONDecoder().decode(ACPToolCall.self, from: Data(#"{"toolCallId":"\#(id)","title":"Edit","kind":"edit","status":"\#(status)","content":[{"type":"diff","path":"/w/a.txt","oldText":"x","newText":"y\#(id)"}]}"#.utf8))
        }
        var turn = AgentTurn(id: "t", prompt: "p", promptAt: Date())
        turn.items = [.tool(try call("1", "completed")), .tool(try call("2", "pending")), .tool(try call("3", "failed"))]
        #expect(turn.edits.map(\.newText) == ["y1"])
        #expect(turn.changeSet?.files.count == 1)
    }

    @Test func svgPreviewsAsMarkup() {
        #expect(TerminalArtifact.kind(forExtension: "svg") == .html)
        #expect(TerminalArtifact.kind(forExtension: "png") == .image)
    }

    final class StuckChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Data?, any Error>?
        private var closed = false
        func send(_ data: Data) async throws {}
        func receive() async throws -> Data? {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if closed { continuation.resume(returning: nil) } else { waiter = continuation }
                }
            }
        }
        func close(code: String, reason: String) async {
            let waiting = lock.withLock { () -> CheckedContinuation<Data?, any Error>? in
                closed = true
                defer { waiter = nil }
                return waiter
            }
            waiting?.resume(returning: nil)
        }
    }

    @Test func aStalledReadGivesUp() async {
        await #expect(throws: ArtifactUnavailable.self) {
            _ = try await LinkFileArtifactSource.receive(StuckChannel(), within: .milliseconds(50), macName: "Studio")
        }
    }
}

@Suite struct FittedSVGTests {
    /// Round 3 live: an SVG previewed at its own size in the top-left corner; it is now
    /// centered and fitted to the page.
    @Test func anSVGIsCenteredAndFitted() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><circle cx="50" cy="50" r="40" fill="red"/></svg>"#
        let page = TerminalArtifact.fittedSVG(svg)
        #expect(page.contains(svg))
        #expect(page.contains("justify-content:center"))
        #expect(page.contains("svg{width:100%;height:100%"))
    }
}
