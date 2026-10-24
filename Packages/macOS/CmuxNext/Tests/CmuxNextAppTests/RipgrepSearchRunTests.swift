import CmuxNextFilesUI
import Foundation
import Testing

/// `RipgrepSearch.run` stops `rg` itself: at the match limit, and when the search is cancelled
/// (the reading task and the cancellation handler share the process only through a lock). A
/// stand-in `rg` script runs instead of ripgrep.
@Suite struct RipgrepSearchRunTests {
    private static let matchLine =
        #"{"type":"match","data":{"path":{"text":"/r/a.txt"},"lines":{"text":"needle\n"},"line_number":1,"submatches":[{"match":{"text":"needle"},"start":0,"end":6}]}}"#

    /// The stand-in never stops printing matches: `run` returns only if it stops reading at the
    /// limit and does not wait for an rg that never exits by itself.
    @Test(.timeLimit(.minutes(1))) func aSearchPastItsLimitStopsRipgrep() async throws {
        try await Self.withFakeRipgrep { _ in "while :; do printf '%s\\n' '\(Self.matchLine)'; done" } body: { rg, root, _ in
            let outcome = await RipgrepSearch.run(rg, query: "needle", root: root, limit: 3)
            guard case .matches(let matches, let limited) = outcome else {
                Issue.record("the search failed: \(outcome)")
                return
            }
            #expect(matches.count == 3)
            #expect(limited)
        }
    }

    /// The stand-in never prints (a long search of a big folder) and holds a FIFO open for writing,
    /// so the FIFO tells the test when rg runs (its open returns) and when rg is gone (end of file).
    /// The search is cancelled only after rg runs: `run` is then reading, and only its cancellation
    /// handler can stop rg. A search cancelled before it starts proves nothing, because a cancelled
    /// task's pipe read and exit wait return at once while rg keeps running. Without the stop in
    /// the cancellation handler the end of file never comes and the time limit fails the test.
    @Test(.timeLimit(.minutes(1))) func aCancelledSearchStopsRipgrep() async throws {
        try await Self.withFakeRipgrep { fifo in "exec /bin/sleep 600 3>'\(fifo)'" } body: { rg, root, fifo in
            var rgLife = Self.watchWriter(of: fifo).makeAsyncIterator()
            let search = Task { await RipgrepSearch.run(rg, query: "needle", root: root) }
            try #require(await rgLife.next() == .started)
            search.cancel()
            try #require(await rgLife.next() == .exited)
            #expect(await search.value == .matches([], limited: false))
        }
    }

    private enum WriterEvent: Equatable, Sendable {
        /// The writer opened the FIFO.
        case started
        /// Every writer closed it (the process that held it is gone).
        case exited
    }

    /// The life of the process that opens `fifo` for writing, read from the FIFO's other end.
    private static func watchWriter(of fifo: String) -> AsyncStream<WriterEvent> {
        let (events, continuation) = AsyncStream.makeStream(of: WriterEvent.self)
        // The blocking open and read of a FIFO have no async form; a thread of their own keeps
        // them off the cooperative pool, and the stream lets the time limit end a test whose
        // writer never comes or never goes.
        Thread.detachNewThread {
            let reader = open(fifo, O_RDONLY)
            guard reader >= 0 else {
                continuation.finish()
                return
            }
            continuation.yield(.started)
            var byte: UInt8 = 0
            while read(reader, &byte, 1) > 0 {}
            close(reader)
            continuation.yield(.exited)
            continuation.finish()
        }
        return events
    }

    /// Runs `body` with an executable `/bin/sh` stand-in for rg (its body is `script(fifo)`), a
    /// folder to search, and the path of a FIFO in that folder.
    private static func withFakeRipgrep(
        _ script: (String) -> String,
        body: (URL, String, String) async throws -> Void
    ) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-rg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appendingPathComponent("rg.fifo").path
        try #require(mkfifo(fifo, 0o600) == 0)
        let rg = folder.appendingPathComponent("rg")
        try "#!/bin/sh\n\(script(fifo))\n".write(to: rg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rg.path)
        try await body(rg, folder.path, fifo)
    }
}
