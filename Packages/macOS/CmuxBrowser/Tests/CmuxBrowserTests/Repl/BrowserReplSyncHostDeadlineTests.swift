import Foundation
import Testing

@testable import CmuxBrowser

/// A synchronous host call (`fs.readFileSync`, `fs.copyFileSync`) runs its
/// file reads and secret masking on the session's only JavaScript thread.
/// The cell's timeout must end that native work too: the call stops with
/// `ECANCELED`, and the next cell runs right after the timeout instead of
/// waiting for the read and the scan to finish.
@Suite("Browser REPL synchronous host deadline", .serialized)
struct BrowserReplSyncHostDeadlineTests {
    /// A held value that shares a long prefix with every position of the
    /// file, so masking it compares many bytes per input byte.
    private static let value = String(repeating: "a", count: 63) + "Z"
    private static let fileBytes = 2 << 20

    @Test(
        "A sync fs call masking a large file ends at the cell's timeout and the next cell runs",
        arguments: [
            #"fs.copyFileSync("big.txt", "copy.txt");"#,
            #"fs.readFileSync("big.txt");"#,
        ]
    )
    func syncHostCallEndsAtTimeout(call: String) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data(repeating: UInt8(ascii: "a"), count: Self.fileBytes).write(to: work.appendingPathComponent("big.txt"))
        let session = BrowserReplSession(
            id: "deadline-\(UUID().uuidString)",
            cwd: work.path,
            bundle: try browserReplRepositoryBundle(),
            driver: ScriptedPageDriver()
        )
        defer { session.close() }

        let setUp = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            globalThis.fs = await import("node:fs");
            secrets.set("k", "\(Self.value)", { domains: ["example.com"] });
            """, timeout: .seconds(30))
        }
        #expect(setUp?.error == nil, "\(setUp?.error ?? "no answer")")

        let clock = ContinuousClock()
        let timedOut = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: call, timeout: .milliseconds(200))
        }
        #expect(timedOut?.error?.contains("timed out") == true, "\(timedOut?.error ?? "no answer")")
        let afterTimeout = clock.now
        let next = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: "console.log('alive');", timeout: .seconds(60))
        }
        let waited = clock.now - afterTimeout

        #expect(next?.lines.map(\.text) == ["alive"], "\(next?.error ?? "no answer")")
        // The native work stops between chunks; it no longer runs on to the
        // end of the file and the scan.
        #expect(waited < .seconds(3), "the next cell waited \(waited) for the timed-out cell's host call")
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("copy.txt").path))
    }

    /// A timer callback that outlives its cell is held to the callback time
    /// limit; a sync fs call inside it stops at that limit too, so the next
    /// cell (whose own timer fires after it) is not held up by the scan.
    @Test("A sync fs call in a callback after its cell ends stops at the callback time limit")
    func syncHostCallInCallbackEndsAtLimit() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-deadline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data(repeating: UInt8(ascii: "a"), count: Self.fileBytes).write(to: work.appendingPathComponent("big.txt"))
        let session = BrowserReplSession(
            id: "deadline-\(UUID().uuidString)",
            cwd: work.path,
            bundle: try browserReplRepositoryBundle(),
            driver: ScriptedPageDriver(),
            callbackTimeLimit: .milliseconds(200)
        )
        defer { session.close() }

        let started = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            const fs = await import("node:fs");
            secrets.set("k", "\(Self.value)", { domains: ["example.com"] });
            setTimeout(() => fs.copyFileSync("big.txt", "copy.txt"), 0);
            """, timeout: .seconds(30))
        }
        #expect(started?.error == nil, "\(started?.error ?? "no answer")")

        let clock = ContinuousClock()
        let begin = clock.now
        // Its own timer fires after the earlier one, so it runs after the copy.
        let next = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: "await new Promise((resolve) => setTimeout(resolve, 1)); console.log('alive');", timeout: .seconds(60))
        }
        let waited = clock.now - begin

        #expect(next?.lines.map(\.text).contains("alive") == true, "\(next?.error ?? "no answer")")
        #expect(waited < .seconds(3), "the next cell waited \(waited) for the callback's host call")
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("copy.txt").path))
    }
}
