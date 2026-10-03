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
