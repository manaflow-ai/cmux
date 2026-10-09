import Foundation
import Testing

@testable import CmuxBrowser

/// A minimal runtime over the native host: `native` is the host itself.
private let levelRuntime = #"""
globalThis.__cmuxHostOnResult = () => {};
globalThis.__cmuxHostOnTimer = () => {};
globalThis.__cmuxHostOnEvent = () => {};
const AsyncFunction = (async () => {}).constructor;
globalThis.__cmuxFormatError = (e) => `${e.name}: ${e.message}`;
globalThis.__cmuxReplEval = (code) => new AsyncFunction("native", code)(__cmuxNative);
"""#

/// Answers every call at once; the output tests make none.
private final class SilentDriver: BrowserReplDriver, @unchecked Sendable {
    var capabilities: [String] { [] }
    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> { .success("null") }
    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}
}

@Suite("Browser REPL output levels", .serialized)
struct BrowserReplOutputLevelTests {
    /// r21 native finding 1: agent code reaches the native print through
    /// the runtime's host with any level. A level is one of the fixed
    /// native set (anything else prints as `log`), and every line the cell
    /// keeps is charged to its in-memory output limit with its level, so
    /// many empty lines cannot hold memory the limit does not count.
    @Test("A print's level is one of the native levels, and each kept line is charged whole")
    func printLevelsAreFixedAndCharged() async throws {
        let limit = 4096
        let session = BrowserReplSession(
            id: "levels-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "levels.js", source: levelRuntime)], agentScripts: []),
            driver: SilentDriver(),
            limits: BrowserReplResourceLimits.standard.with(.retainedOutputBytes, limit),
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
        defer { session.close() }
        let result = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: """
            native.print("x".repeat(100000), "large");
            native.print(42, "number");
            native.print({ toString() { return "warn"; } }, "object");
            for (const level of ["log", "info", "warn", "error", "debug"]) native.print(level, level);
            for (let i = 0; i < 5000; i++) native.print("log", "");
            """, timeout: .seconds(100))
        }
        let lines = try #require(result?.lines)
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        let native: Set<String> = ["log", "info", "warn", "error", "debug"]
        let foreign = lines.filter { !native.contains($0.level) }.map { String($0.level.prefix(40)) }
        #expect(foreign.isEmpty, "levels outside the native set were kept: \(Set(foreign))")
        let first = lines.prefix(3).map { String($0.level.prefix(40)) }
        #expect(first == ["log", "log", "log"], "\(first)")
        #expect(lines.dropFirst(3).prefix(5).map(\.level) == ["log", "info", "warn", "error", "debug"])
        // What the cell kept (its notes aside) fits the limit with levels counted.
        let kept = lines.filter { !$0.text.hasPrefix("# ") }
        let bytes = kept.reduce(0) { $0 + $1.level.utf8.count + $1.text.utf8.count + 1 }
        #expect(bytes <= limit, "the cell kept \(kept.count) lines holding \(bytes) bytes past its \(limit)-byte limit")
        #expect(lines.contains { $0.text.hasPrefix("# output") }, "the lines past the limit were not reported")
    }
}
