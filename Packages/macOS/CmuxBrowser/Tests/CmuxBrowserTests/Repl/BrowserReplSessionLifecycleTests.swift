import Foundation
import Testing

@testable import CmuxBrowser

/// A runtime that hands the cell the raw native host, so a cell can call
/// `native.setTimer` and the driver directly.
private let lifecycleRuntime = #"""
const pending = new Map();
let nextCall = 1;
const timers = new Map();
globalThis.__cmuxHostOnResult = (id, error, result) => {
  const p = pending.get(id); pending.delete(id);
  if (!p) return;
  if (error) p.reject(new Error(JSON.parse(error).message)); else p.resolve(JSON.parse(result));
};
globalThis.__cmuxHostOnTimer = (id) => { const t = timers.get(id); if (t) { timers.delete(id); t(); } };
const native = __cmuxNative;
const call = (method, params) => new Promise((resolve, reject) => {
  const id = nextCall++; pending.set(id, { resolve, reject });
  native.driverCall(id, method, JSON.stringify(params ?? {}));
});
const timer = (id, ms) => new Promise((r) => { timers.set(id, r); native.setTimer(id, ms, false); });
const console = { log: (...a) => native.print("log", a.map(String).join(" ")) };
const AsyncFunction = (async () => {}).constructor;
globalThis.__cmuxFormatError = (e) => `${e.name}: ${e.message}`;
globalThis.__cmuxReplEval = (code) => new AsyncFunction("console", "call", "timer", "native", code)(console, call, timer, native);
"""#

@Suite("Browser REPL session lifecycle")
struct BrowserReplSessionLifecycleTests {
    private func makeSession(
        driver: any BrowserReplDriver,
        bundle: BrowserReplRuntimeBundle? = nil
    ) -> BrowserReplSession {
        BrowserReplSession(
            id: "lifecycle-\(UUID().uuidString)",
            cwd: FileManager.default.temporaryDirectory.path,
            bundle: bundle ?? BrowserReplRuntimeBundle(
                replScripts: [.init(name: "lifecycle.js", source: lifecycleRuntime)],
                agentScripts: []
            ),
            driver: driver
        )
    }

    @Test("Timer delays that are huge, negative, NaN or infinite are clamped instead of trapping")
    func outOfRangeTimerDelays() async {
        let session = makeSession(driver: RecordingReplDriver())
        defer { session.close() }

        let result = await browserReplWithDeadline(seconds: 20) {
            await session.evaluate(code: """
            native.setTimer(101, 1e20, false);
            native.setTimer(102, Infinity, true);
            native.setTimer(103, -Infinity, false);
            native.setTimer(104, Number.MAX_VALUE, false);
            await timer(105, NaN);
            await timer(106, -5);
            console.log("fired");
            """)
        }
        #expect(result?.error == nil)
        #expect(result?.lines == [BrowserReplOutputLine(level: "log", text: "fired")])
    }

    @Test("A synchronous infinite loop times out and the session stays usable")
    func synchronousLoopTimesOut() async {
        let session = makeSession(driver: RecordingReplDriver())
        defer { session.close() }

        let hung = await browserReplWithDeadline(seconds: 20) {
            await session.evaluate(code: "while (true) {}", timeout: .milliseconds(300))
        }
        #expect(hung?.error?.contains("timed out") == true)

        let next = await browserReplWithDeadline(seconds: 20) {
            await session.evaluate(code: "console.log('alive');", timeout: .seconds(10))
        }
        #expect(next?.lines == [BrowserReplOutputLine(level: "log", text: "alive")])
    }

    @Test("A cell that never settles is cancelled at its timeout and later cells run (real runtime)")
    func hungCellDoesNotBlockLaterCells() async throws {
        let session = makeSession(driver: RecordingReplDriver(), bundle: try browserReplRepositoryBundle())
        defer { session.close() }

        let hung = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "await new Promise(() => {});", timeout: .milliseconds(300))
        }
        #expect(hung?.error?.contains("timed out") == true)

        let next = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "1 + 1", timeout: .seconds(10))
        }
        #expect(next?.error == nil)
        #expect(next?.lines.map(\.text) == ["2"])
    }

    @Test("A synchronous loop in the real runtime times out and later cells run")
    func realRuntimeLoopTimesOut() async throws {
        let session = makeSession(driver: RecordingReplDriver(), bundle: try browserReplRepositoryBundle())
        defer { session.close() }

        let hung = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "await 0; for (;;) {}", timeout: .milliseconds(300))
        }
        #expect(hung?.error?.contains("timed out") == true)

        let next = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "const x = 20; x + 1", timeout: .seconds(10))
        }
        #expect(next?.error == nil)
        #expect(next?.lines.map(\.text) == ["21"], "\(String(describing: next))")
    }

    @Test("A cell terminated with a tab update pending leaves later calls on that tab usable")
    func terminatedCellLeavesTabUsable() async throws {
        let driver = ScriptedPageDriver()
        let session = makeSession(driver: driver, bundle: try browserReplRepositoryBundle())
        defer { session.close() }

        let opened = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "await page.goto('https://example.com/login')", timeout: .seconds(10))
        }
        #expect(opened?.error == nil)
        // Inside a microtask drain, adding a dialog listener queues a
        // tab.handleEvents update; terminating the loop drops that job.
        let hung = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "await 0; page.on('dialog', () => {}); for (;;) {}", timeout: .milliseconds(300))
        }
        #expect(hung?.error?.contains("timed out") == true)

        let next = await browserReplWithDeadline(seconds: 40) {
            await session.evaluate(code: "await page.title()", timeout: .seconds(15))
        }
        #expect(next?.error == nil, "\(String(describing: next?.error))")
        #expect(next?.lines.map(\.text) == ["Login"])
    }

    @Test("close() cancels in-flight driver calls and the evaluation returns")
    func closeCancelsInFlightDriverCalls() async {
        let driver = GatedReplDriver()
        let session = makeSession(driver: driver)

        let evaluation = Task { await session.evaluate(code: "await call('slow');", timeout: .seconds(30)) }
        await driver.waitUntilSlowCallStarted()
        session.close()
        let result = await browserReplWithDeadline(seconds: 20) { await evaluation.value }
        #expect(result?.error?.contains("closed") == true)

        driver.release()
        // The call's task observes the cancellation once it resumes.
        for _ in 0..<200 where driver.cancelledAfterRelease.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(driver.cancelledAfterRelease == [true])
    }

    @Test("Evaluations racing close() always return and never re-attach the driver")
    func evaluateRacingClose() async {
        for _ in 0..<200 {
            let driver = GatedReplDriver()
            let session = makeSession(driver: driver)
            _ = await session.evaluate(code: "1")
            let attachedBefore = driver.attachCount
            async let racing = browserReplWithDeadline(seconds: 10) { await session.evaluate(code: "1") }
            session.close()
            let result = await racing
            #expect(result != nil)
            #expect(driver.attachCount == attachedBefore)
            if result == nil { break }
        }
    }
}

@Suite("Browser REPL fetcher lifecycle")
struct BrowserReplFetcherLifecycleTests {
    @Test("A fetch after invalidate() fails with closed instead of crashing")
    func fetchAfterInvalidate() async {
        let fetcher = BrowserReplFetcher(driver: RecordingReplDriver())
        fetcher.invalidate()
        let result = await fetcher.fetch(requestJSON: #"{"url":"http://127.0.0.1:9/"}"#)
        guard case .failure(let error) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(error.code == "closed")
    }

    @Test("invalidate() during the cookie lookup fails the fetch instead of crashing")
    func invalidateDuringCookieLookup() async {
        let driver = CookieGateDriver()
        let fetcher = BrowserReplFetcher(driver: driver)
        let fetch = Task { await fetcher.fetch(requestJSON: #"{"url":"http://127.0.0.1:9/"}"#) }
        await driver.waitForCookieLookup()
        fetcher.invalidate()
        driver.release()
        let result = await fetch.value
        guard case .failure(let error) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(error.code == "closed")
    }
}

/// Holds `cookies.get` until `release()`.
private final class CookieGateDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var lookup: CheckedContinuation<Void, Never>?
    private var lookupStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        guard method == "cookies.get" else { return .success("null") }
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            lookupStarted = true
            defer { startWaiter = nil }
            return startWaiter
        }
        waiter?.resume()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                lookup = continuation
                lock.unlock()
            }
        }
        return .success("[]")
    }

    func waitForCookieLookup() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if lookupStarted {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { lookup = nil }
            return lookup
        }
        pending?.resume()
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}
}
