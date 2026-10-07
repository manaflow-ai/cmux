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
            cwd: browserReplTestWorkingDirectory,
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

    @Test("In JavaScriptCore, a timed-out cell's late output is dropped and its functions still print")
    func cancelledCellOutputInJavaScriptCore() async throws {
        let session = makeSession(driver: RecordingReplDriver(), bundle: try browserReplRepositoryBundle())
        defer { session.close() }
        let hung = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(
                code: "function hello() { console.log('hello'); } setTimeout(() => console.log('late from cell 1'), 400); await new Promise(() => {})",
                timeout: .milliseconds(200)
            )
        }
        #expect(hung?.error?.contains("timed out") == true)
        let next = await browserReplWithDeadline(seconds: 30) {
            // Cell 2 outlasts cell 1's timer, whose output (if it ran) is dropped.
            await session.evaluate(code: "hello(); await new Promise((r) => setTimeout(r, 800)); console.log('cell 2')", timeout: .seconds(10))
        }
        #expect(next?.error == nil)
        #expect(next?.lines.map(\.text) == ["hello", "cell 2"])
    }

    /// r16 native#3: a cell that times out is over, so the timers it set
    /// (and the timers they set, an interval re-arming itself) are cancelled
    /// with it, as its fetches and driver calls are; none can act in a later
    /// cell. Timers fire in deadline order, so cell 2's longer timer firing
    /// shows cell 1's would have fired by then.
    @Test("A timed-out cell's timers and intervals are cancelled and never run in later cells")
    func timedOutCellTimersAreCancelled() async throws {
        let session = makeSession(driver: RecordingReplDriver(), bundle: try browserReplRepositoryBundle())
        defer { session.close() }
        let hung = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(
                code: """
                globalThis.ran = [];
                setTimeout(() => ran.push("timeout"), 400);
                setInterval(() => ran.push("interval"), 50);
                setTimeout(() => setTimeout(() => ran.push("nested"), 100), 0);
                await new Promise(() => {});
                """,
                timeout: .milliseconds(200)
            )
        }
        #expect(hung?.error?.contains("timed out") == true)
        let next = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(
                code: "ran.length = 0; await new Promise((r) => setTimeout(r, 800)); console.log(JSON.stringify(ran))",
                timeout: .seconds(10)
            )
        }
        #expect(next?.error == nil, "\(String(describing: next?.error))")
        #expect(next?.lines.map(\.text) == ["[]"], "\(String(describing: next?.lines.map(\.text)))")
    }

    /// r17 native#2: a cell that times out while it awaits a promise
    /// something else settles later (a page event, a value another cell
    /// provides) is over; when that promise settles during a later cell,
    /// the old cell's code resumes, but it does no native work (fs, driver
    /// calls), in its own body or in an async function it awaits.
    @Test("A timed-out cell that resumes later is refused native work")
    func resumedTimedOutCellIsRefusedNativeWork() async throws {
        let driver = RecordingReplDriver()
        let session = makeSession(driver: driver, bundle: try browserReplRepositoryBundle())
        defer { session.close() }
        let hung = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(
                code: """
                await new Promise((r) => { globalThis.resume = r; });
                const results = [];
                try { fs.writeFileSync(os.tmpdir() + "/stale.txt", "x"); results.push("fs ran"); } catch (e) { results.push("fs " + e.code); }
                async function helper() {
                  await new Promise((r) => { globalThis.resumeHelper = r; });
                  try { await tabs.list(); return "driver ran"; } catch (e) { return "driver " + e.code; }
                }
                results.push(await helper());
                globalThis.outcome = results;
                """,
                timeout: .milliseconds(200)
            )
        }
        #expect(hung?.error?.contains("timed out") == true)
        let callsBefore = driver.calls.filter { $0 == "tabs.list" }.count
        let next = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(
                code: """
                resume();
                for (let i = 0; i < 400 && !globalThis.resumeHelper; i++) await new Promise((r) => setTimeout(r, 5));
                resumeHelper();
                for (let i = 0; i < 400 && !globalThis.outcome; i++) await new Promise((r) => setTimeout(r, 5));
                console.log(JSON.stringify(globalThis.outcome));
                console.log(fs.existsSync(os.tmpdir() + "/stale.txt"));
                """,
                timeout: .seconds(10)
            )
        }
        #expect(next?.error == nil, "\(String(describing: next?.error))")
        #expect(next?.lines.map(\.text) == [#"["fs cancelled","driver cancelled"]"#, "false"], "\(String(describing: next?.lines.map(\.text)))")
        #expect(driver.calls.filter { $0 == "tabs.list" }.count == callsBefore, "the resumed cell reached the driver")
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

/// A cell that arms a timer whose callback never returns, and evaluates to
/// the timer's id. The hour never elapses in a test: the test fires the
/// timer itself through the session's timer entry point, so nothing waits
/// on wall-clock time.
private let armRunawayTimerCell = "setTimeout(() => { for (;;) {} }, 3600000)"

/// Sleeps on the continuous clock and reports each sleep it starts. The
/// session starts a cell's timeout right after it made the cell current
/// and queued it on its thread, so a test learns from this when that has
/// happened.
private final class ReportingSleeper: BrowserReplSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [Duration] = []
    private var waiters: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            started.append(duration)
            let matched = waiters.filter { $0.duration == duration }.map(\.continuation)
            waiters.removeAll { $0.duration == duration }
            return matched
        }
        for waiter in ready { waiter.resume() }
        try await ContinuousClock().sleep(for: duration)
    }

    /// Returns once a sleep of `duration` has started.
    func waitUntilSleeping(for duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if started.contains(duration) { return true }
                waiters.append((duration, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }
}

/// Agent code runs in the session's JavaScript context and can reach any
/// object there. Every JavaScript run on the session's thread, not only a
/// cell, is bounded, and closing (`cmux browser repl reset`) always ends it.
@Suite("Browser REPL session watchdog")
struct BrowserReplSessionWatchdogTests {
    private func makeSession(
        callbackTimeLimit: Duration = BrowserReplSession.defaultCallbackTimeLimit,
        sleeper: any BrowserReplSleeping = BrowserReplClockSleeper(clock: ContinuousClock())
    ) throws -> BrowserReplSession {
        BrowserReplSession(
            id: "watchdog-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: try browserReplRepositoryBundle(),
            driver: RecordingReplDriver(),
            sleeper: sleeper,
            callbackTimeLimit: callbackTimeLimit
        )
    }

    /// Runs ``armRunawayTimerCell`` and returns the timer's id.
    private func armRunawayTimer(in session: BrowserReplSession) async throws -> Int {
        let armed = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: armRunawayTimerCell, timeout: .seconds(20))
        }
        #expect(armed?.error == nil)
        return try #require(armed?.lines.first.flatMap { Int($0.text) }, "\(String(describing: armed))")
    }

    @Test("A cell cannot call the app's entry points or reach the runtime's constructors")
    func entryPointsAreNotInCellScope() async throws {
        let session = try makeSession()
        defer { session.close() }
        let result = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: """
            [typeof __cmuxReplEval, typeof __cmuxReplCancel, typeof __cmuxHostOnResult, typeof __cmuxHostOnTimer,
             typeof __cmuxHostOnEvent, typeof __cmuxFormatError, typeof __cmuxNative, typeof CmuxBrowserRepl].join(",")
            """, timeout: .seconds(20))
        }
        #expect(result?.error == nil)
        #expect(result?.lines.map(\.text) == [Array(repeating: "undefined", count: 8).joined(separator: ",")])
    }

    @Test("A timer callback that never returns after its cell ended is stopped, and the next cell runs")
    func runawayCallbackOutsideACellIsStopped() async throws {
        // A zero budget stops a run outside a cell at the watchdog's first check.
        let session = try makeSession(callbackTimeLimit: .zero)
        defer { session.close() }
        let timer = try await armRunawayTimer(in: session)
        // The timer elapses while no cell runs; its callback starts at once.
        session.fireTimer(timer)
        // A block queued behind the callback runs once the watchdog stopped it.
        let freed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if !session.thread.perform({ continuation.resume(returning: true) }) {
                continuation.resume(returning: false)
            }
        }
        #expect(freed)
        let next = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: "1 + 1", timeout: .seconds(30))
        }
        #expect(next?.error == nil, "\(String(describing: next?.error))")
        // The next cell says the callback was stopped, then prints its value.
        #expect(next?.lines.map(\.text).last == "2")
        #expect(next?.lines.first.map { $0.level == "error" && $0.text.contains("was stopped") } == true, "\(String(describing: next?.lines))")
    }

    /// The next cell is current as soon as it is submitted, but it runs only
    /// once the thread reaches it. A callback queued ahead of it is not that
    /// cell's work: counting it as the cell's would exempt it from the
    /// callback budget, so it would hold the thread until the cell timed out.
    @Test("A timer callback queued ahead of the next cell is not counted as that cell's: it is stopped and the cell runs")
    func runawayCallbackQueuedAheadOfACellIsStopped() async throws {
        let sleeper = ReportingSleeper()
        let session = try makeSession(callbackTimeLimit: .zero, sleeper: sleeper)
        defer { session.close() }
        let timer = try await armRunawayTimer(in: session)

        // Hold the thread so the callback and the next cell queue behind it, in that order.
        let hold = DispatchSemaphore(value: 0)
        defer { hold.signal() }
        #expect(session.thread.perform { hold.wait() })
        session.fireTimer(timer)
        let cellTimeout = Duration.seconds(30)
        async let next = browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: "1 + 1", timeout: cellTimeout)
        }
        // The cell is current and queued once its timeout started.
        await sleeper.waitUntilSleeping(for: cellTimeout)
        hold.signal()

        let result = await next
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        #expect(result?.lines.map(\.text).last == "2")
        #expect(result?.lines.first?.text.contains("was stopped") == true, "\(String(describing: result?.lines))")
    }

    /// Each callback stays under the per-run limit, but together they would
    /// hold the thread for minutes ahead of the next cell.
    @Test("A stream of slow timer callbacks between cells cannot starve the next cell, which says why they waited")
    func slowCallbacksCannotStarveTheNextCell() async throws {
        let session = try makeSession(callbackTimeLimit: .seconds(1))
        defer { session.close() }
        let armed = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: """
            for (let i = 0; i < 100; i++) setTimeout(() => { const end = Date.now() + 900; while (Date.now() < end) {} }, 0);
            // The timers come due while this loop holds the thread, so their
            // callbacks are queued ahead of the next cell.
            const until = Date.now() + 300;
            while (Date.now() < until) {}
            """, timeout: .seconds(20))
        }
        #expect(armed?.error == nil, "\(String(describing: armed?.error))")

        let next = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "console.log('ran')", timeout: .seconds(20))
        }
        let lines = try #require(next?.lines, "the next cell waited behind the callbacks")
        #expect(next?.error == nil, "\(String(describing: next?.error))")
        #expect(lines.last?.text == "ran")
        #expect(lines.contains { $0.level == "error" && $0.text.contains("callbacks outside a cell may use at most 10%") }, "\(lines)")
    }

    @Test("close() ends the session's thread even when agent code loops in the timed-out cell's cleanup")
    func closeEndsALoopThatStartsAfterTheTimeout() async throws {
        let session = try makeSession(callbackTimeLimit: .seconds(60))
        let thread = session.thread
        // The runtime calls this while it cancels a timed-out cell.
        let patched = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "page._session._resetPendingState = () => { for (;;) {} }; 'patched'", timeout: .seconds(20))
        }
        #expect(patched?.error == nil)
        // The cell is still running when it times out, so the timeout's
        // cleanup (which cancels the cell) waits behind it on the thread.
        let hung = await browserReplWithDeadline(seconds: 30) {
            await session.evaluate(code: "const end = Date.now() + 3000; while (Date.now() < end) {} await new Promise(() => {});", timeout: .milliseconds(500))
        }
        #expect(hung?.error?.contains("timed out") == true)
        session.close()
        let exited = await Task.detached { thread.waitUntilExited(timeout: .seconds(15)) }.value
        #expect(exited, "the session's JavaScript thread kept running after close()")
    }
}
