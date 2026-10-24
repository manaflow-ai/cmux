import Foundation
import Testing
@testable import CmuxNextWakeups

/// The typing probe samples only the terminal a key went to: with 20 busy terminals, another terminal's output,
/// parse and frame used to pass for the typed key's echo (PL-script finding 5b: rows that measured the wrong
/// terminal). A mark scoped to another terminal is ignored; the typed terminal's own marks complete the row, which
/// closes at the commit after its contents (`contents_commit_ms`).
@Suite(.serialized)
struct TypingLatencyProbeScopeTests {
    private static func probe() throws -> (TypingLatencyProbe, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typing-probe-\(UUID().uuidString).csv")
        return (TypingLatencyProbe(path: url.path), url)
    }

    private static func rows(_ probe: TypingLatencyProbe, _ url: URL) throws -> [[String: String]] {
        probe.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let header = try #require(lines.first).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        return lines.dropFirst().map { line in
            Dictionary(uniqueKeysWithValues: zip(header, line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)))
        }
    }

    /// Every hop from ioWrite to the commit after contents, scoped as the terminal `surface`/`view` makes them.
    private static func echo(_ probe: TypingLatencyProbe, surface: UInt64, view: Int, layer: ObjectIdentifier) {
        probe.mark(.ioWrite, scope: .view(view))
        probe.mark(.socketSubmit, scope: .surface(surface))
        probe.mark(.outputDecoded, scope: .surface(surface))
        probe.mark(.outputReceived, scope: .view(view))
        probe.mark(.outputParsed, scope: .view(view))
        probe.register(layer: layer, view: view)
        probe.markContents(layer: layer)
        probe.mark(.contentsCommit)
    }

    @Test func anotherTerminalsEchoIsNotTheTypedKeys() throws {
        let (probe, url) = try Self.probe()
        defer { try? FileManager.default.removeItem(at: url) }
        let typed = NSObject(), busy = NSObject()
        probe.keyDown(eventTimestamp: ProcessInfo.processInfo.systemUptime, target: .init(surface: 1, view: 10))
        // A busy terminal prints: every hop of its output, its frame and the commit after it.
        Self.echo(probe, surface: 2, view: 20, layer: ObjectIdentifier(busy))
        // The next key closes the open sample: unfinished if the busy terminal's marks were refused.
        probe.keyDown(eventTimestamp: ProcessInfo.processInfo.systemUptime, target: .init(surface: 1, view: 10))
        Self.echo(probe, surface: 1, view: 10, layer: ObjectIdentifier(typed))
        let rows = try Self.rows(probe, url)
        try #require(rows.count == 2, "\(rows.count) rows")
        #expect(rows[0]["complete"] == "0", "the busy terminal's echo completed the typed key's row")
        #expect(rows[0]["output_parsed_ms"] == "", "the busy terminal's parse was taken for the typed key's")
        #expect(rows[0]["contents_ms"] == "", "the busy terminal's frame was taken for the typed key's")
        #expect(rows[1]["complete"] == "1", "the typed terminal's own echo did not complete its row")
        #expect(rows[1]["contents_commit_ms"] != "", "the row has no commit after its contents")
    }

    @Test func anUntargetedKeyTakesAnyTerminalAsBefore() throws {
        let (probe, url) = try Self.probe()
        defer { try? FileManager.default.removeItem(at: url) }
        probe.keyDown(eventTimestamp: ProcessInfo.processInfo.systemUptime)
        Self.echo(probe, surface: 2, view: 20, layer: ObjectIdentifier(NSObject()))
        let rows = try Self.rows(probe, url)
        #expect(rows.first?["complete"] == "1", "a key with no target refused a terminal's scoped marks")
    }
}
