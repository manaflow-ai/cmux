import Foundation
import Testing

@testable import CmuxBrowser

/// A minimal runtime over the native host: `fetchOnce(url)` and `sleep(ms)`
/// return promises, `native` is the host itself.
private let resourceRuntime = #"""
const pending = new Map();
let nextCall = 1;
const timers = new Map();
let nextTimer = 1;
globalThis.__cmuxHostOnResult = (id, error, result) => {
  const p = pending.get(id); pending.delete(id);
  if (!p) return;
  if (error) p.reject(Object.assign(new Error(JSON.parse(error).message), { code: JSON.parse(error).code }));
  else p.resolve(JSON.parse(result));
};
globalThis.__cmuxHostOnTimer = (id) => { const t = timers.get(id); if (t) { timers.delete(id); t(); } };
globalThis.__cmuxHostOnEvent = () => {};
const fetchOnce = (url) => new Promise((resolve, reject) => {
  const id = nextCall++; pending.set(id, { resolve, reject });
  __cmuxNative.fetch(id, JSON.stringify({ url }));
});
const sleep = (ms) => new Promise((r) => { const id = nextTimer++; timers.set(id, r); __cmuxNative.setTimer(id, ms, false); });
const console = { log: (...a) => __cmuxNative.print("log", a.map(String).join(" ")) };
const AsyncFunction = (async () => {}).constructor;
globalThis.__cmuxFormatError = (e) => `${e.name}: ${e.message}`;
globalThis.__cmuxReplEval = (code) =>
  new AsyncFunction("console", "fetchOnce", "sleep", "native", code)(console, fetchOnce, sleep, __cmuxNative);
"""#

/// Holds every `cookies.get` (the fetcher's first step for a cookie-bearing
/// request) until `releaseAll()`, and records for each one how many
/// responses `responses` had sent when it arrived, and whether it was cancelled.
final class HeldCookiesDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var responsesAtEntry: [Int] = []
    private(set) var cancelledCount = 0
    let responses: @Sendable () -> Int

    init(responses: @escaping @Sendable () -> Int = { 0 }) {
        self.responses = responses
    }

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        guard method == "cookies.get" else { return .success("null") }
        let id = UUID()
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            responsesAtEntry.append(responses())
            let count = responsesAtEntry.count
            let satisfied = entryWaiters.filter { $0.count <= count }.map(\.continuation)
            entryWaiters.removeAll { $0.count <= count }
            return satisfied
        }
        for waiter in ready { waiter.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if released || Task.isCancelled { return true }
                    held[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let (continuation, waiters): (CheckedContinuation<Void, Never>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
                cancelledCount += 1
                defer { cancellationWaiters.removeAll() }
                return (held.removeValue(forKey: id), cancellationWaiters)
            }
            continuation?.resume()
            for waiter in waiters { waiter.resume() }
        }
        return .success("[]")
    }

    /// Returns once `count` calls have arrived.
    func waitForEntries(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if responsesAtEntry.count >= count { return true }
                entryWaiters.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Returns once a held call has been cancelled.
    func waitForCancellation() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if cancelledCount > 0 { return true }
                cancellationWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func releaseAll() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { held.removeAll() }
            return Array(held.values)
        }
        for continuation in pending { continuation.resume() }
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}
}

/// Counts what a test server answered.
final class BrowserReplResponseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() { lock.withLock { value += 1 } }
}

@Suite("Browser REPL session resources", .serialized)
struct BrowserReplSessionResourceTests {
    private func makeSession(_ driver: any BrowserReplDriver) -> BrowserReplSession {
        BrowserReplSession(
            id: "resources-\(UUID().uuidString)",
            cwd: FileManager.default.temporaryDirectory.path,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "resources.js", source: resourceRuntime)], agentScripts: []),
            driver: driver
        )
    }

    @Test("A session holds at most 10,000 pending timers, also while their callbacks wait for a busy thread")
    func pendingTimersAreBounded() async throws {
        let session = BrowserReplSession(
            id: "timers-\(UUID().uuidString)",
            cwd: FileManager.default.temporaryDirectory.path,
            bundle: try browserReplRepositoryBundle(),
            driver: HeldCookiesDriver()
        )
        defer { session.close() }

        // Zero-delay timers fire at once, but this loop keeps the JS thread
        // busy, so every callback is still waiting to run. The last callback
        // to run settles `floodRan`.
        let flood = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            let n = 0;
            globalThis.floodRan = new Promise((resolve) => {
              let ran = 0;
              try {
                for (let i = 0; i < 20001; i++) { setTimeout(() => { if (++ran === n) resolve(ran); }, 0); n++; }
              } catch (e) {
                console.log(e.name, n);
              }
            });
            // The cell's value is not the promise, so the cell does not wait for it.
            undefined;
            """)
        }
        #expect(flood?.error == nil)
        #expect(flood?.lines.map(\.text) == ["RangeError 10000"])

        let ran = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: "console.log(await globalThis.floodRan)")
        }
        #expect(ran?.lines.map(\.text) == ["10000"])

        // Once those callbacks ran, every slot is free again: the session
        // takes 10,000 timers (none of which comes due) once more.
        let refill = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            const ids = [];
            for (let i = 0; i < 10000; i++) ids.push(setTimeout(() => {}, 3600000));
            ids.forEach(clearTimeout);
            console.log(ids.length);
            """)
        }
        #expect(refill?.error == nil, "\(String(describing: refill?.error))")
        #expect(refill?.lines.map(\.text) == ["10000"])
    }

    @Test("Output past the native ceiling goes to a file in the session's temporary directory")
    func nativeOutputCeilingSpillsToAFile() async throws {
        let session = makeSession(HeldCookiesDriver())
        defer { session.close() }

        // 20 MiB straight to the native host, past any runtime output gate.
        let result = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            const line = "x".repeat(1 << 20);
            for (let i = 0; i < 20; i++) native.print("log", line);
            native.print("log", "last");
            """)
        }
        let lines = try #require(result?.lines)
        let retained = lines.reduce(0) { $0 + $1.text.utf8.count + 1 }
        #expect(retained <= 16 << 20, "retained \(retained) bytes in \(lines.count) lines")
        let summary = try #require(lines.last?.text)
        let path = try #require(summary.range(of: "full output: ").map { String(summary[$0.upperBound...]) }, "\(summary)")
        let temporary = await session.evaluate(code: "native.print('log', native.tmpdir);")
        #expect(path.hasPrefix((temporary.lines.first?.text ?? "?") + "/"))
        let spilled = try String(contentsOfFile: path, encoding: .utf8)
        #expect(spilled.hasSuffix("last\n"))
        #expect(lines.contains { $0.text.hasPrefix("# output continues in ") })
    }

    @Test("A cell that times out cancels the fetches it started")
    func timeoutCancelsTheCellsFetches() async {
        let driver = HeldCookiesDriver()
        let session = makeSession(driver)
        defer { session.close() }

        let result = await session.evaluate(
            code: "fetchOnce('http://127.0.0.1:9/held'); await new Promise(() => {});",
            timeout: .milliseconds(100)
        )
        #expect(result.error?.contains("timed out") == true)

        // The fetch was waiting for its cookies; the timeout cancels it, not close().
        let cancelled = await browserReplWithDeadline(seconds: 10) { await driver.waitForCancellation() }
        #expect(cancelled != nil)
        #expect(!session.isClosed)
    }

    @Test("A session runs at most 16 fetches at once; the rest start as earlier ones finish")
    func fetchConcurrencyIsBounded() async throws {
        let counter = BrowserReplResponseCounter()
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            counter.increment()
            return (200, ["Content-Type": "text/plain"], Data("ok".utf8))
        }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver(responses: { counter.count })
        let session = makeSession(driver)
        defer { session.close() }

        let base = "http://127.0.0.1:\(server.port)"
        let evaluation = Task {
            await session.evaluate(code: """
            const results = await Promise.all(Array.from({ length: 40 }, (_, i) => fetchOnce("\(base)/?i=" + i)));
            console.log(results.filter((r) => r.status === 200).length);
            """)
        }
        let started = await browserReplWithDeadline(seconds: 30) { await driver.waitForEntries(16) }
        #expect(started != nil)
        driver.releaseAll()
        let result = await browserReplWithDeadline(seconds: 60) { await evaluation.value }

        #expect(result?.error == nil)
        #expect(result?.lines.map(\.text) == ["40"])
        // The 17th fetch starts only after one has its response, the 18th after two, and so on.
        let arrivals = driver.responsesAtEntry
        #expect(arrivals.count == 40)
        for (index, responses) in arrivals.enumerated() where index >= 16 {
            #expect(responses >= index - 15, "fetch \(index + 1) started after \(responses) responses: \(arrivals)")
        }
    }
}
