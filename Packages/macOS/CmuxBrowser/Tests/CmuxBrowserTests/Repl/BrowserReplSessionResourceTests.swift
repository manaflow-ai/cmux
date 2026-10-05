import Foundation
import Network
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
const driverOnce = (method) => new Promise((resolve, reject) => {
  const id = nextCall++; pending.set(id, { resolve, reject });
  __cmuxNative.driverCall(id, method, "{}");
});
const sleep = (ms) => new Promise((r) => { const id = nextTimer++; timers.set(id, r); __cmuxNative.setTimer(id, ms, false); });
const console = { log: (...a) => __cmuxNative.print("log", a.map(String).join(" ")) };
const AsyncFunction = (async () => {}).constructor;
globalThis.__cmuxFormatError = (e) => `${e.name}: ${e.message}`;
globalThis.__cmuxReplEval = (code) =>
  new AsyncFunction("console", "fetchOnce", "driverOnce", "sleep", "native", code)(console, fetchOnce, driverOnce, sleep, __cmuxNative);
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

/// Passes calls to `inner` and counts the finished ones in `completed`.
final class BrowserReplCountingDriver: BrowserReplDriver, @unchecked Sendable {
    private let inner: any BrowserReplDriver
    private let completed: BrowserReplResponseCounter

    init(_ inner: any BrowserReplDriver, completed: BrowserReplResponseCounter) {
        self.inner = inner
        self.completed = completed
    }

    var capabilities: [String] { inner.capabilities }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        let result = await inner.call(method: method, paramsJSON: paramsJSON)
        completed.increment()
        return result
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

/// A driver whose typed-secret store, which the session reads every time
/// it redacts, can be made to block once: it stands in for a redaction
/// that takes a long time, and records whether it ran on the session's
/// JavaScript thread.
final class SlowRedactionDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: BrowserReplDriverEventSink?
    private var armed = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isBlocked = false
    private let release = DispatchSemaphore(value: 0)
    private(set) var blockedThreadName: String?

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        if method == "emitThenReturn" {
            // The event's redaction blocks, so a result that did not wait
            // for the events before it would arrive first.
            armBlockingRedaction()
            emit("console", #"{"targetId":"t1","type":"log","text":"before the result"}"#)
            await waitUntilBlocked()
        }
        return .success("null")
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) { lock.withLock { sink = eventSink } }

    func detach() { lock.withLock { sink = nil } }

    func emit(_ name: String, _ payload: String) {
        let sink = lock.withLock { self.sink }
        sink?(name, payload)
    }

    /// The next redaction blocks until `releaseRedaction()`.
    func armBlockingRedaction() { lock.withLock { armed = true } }

    func releaseRedaction() { release.signal() }

    /// Returns once the armed redaction is blocked.
    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if isBlocked { return true }
                blockedWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func typedSecretRedaction() -> BrowserReplSecretStore? {
        let waiters: [CheckedContinuation<Void, Never>]? = lock.withLock {
            guard armed else { return nil }
            armed = false
            isBlocked = true
            blockedThreadName = Thread.current.name
            defer { blockedWaiters = [] }
            return blockedWaiters
        }
        guard let waiters else { return nil }
        for waiter in waiters { waiter.resume() }
        release.wait()
        return nil
    }
}

@Suite("Browser REPL session resources", .serialized)
struct BrowserReplSessionResourceTests {
    private func makeSession(_ driver: any BrowserReplDriver) -> BrowserReplSession {
        BrowserReplSession(
            id: "resources-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "resources.js", source: resourceRuntime)], agentScripts: []),
            driver: driver
        )
    }

    /// The cap is lowered to 100 so the test does not depend on how fast the
    /// machine schedules 10,000 timers; production keeps
    /// `BrowserReplSession.maxPendingTimers`. That fired timers count until
    /// their callback runs is covered by `BrowserReplTimerSchedulerTests`.
    @Test("A session's pending timers are bounded, and slots free once their callbacks ran")
    func pendingTimersAreBounded() async throws {
        let cap = 100
        let session = BrowserReplSession(
            id: "timers-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: try browserReplRepositoryBundle(),
            driver: HeldCookiesDriver(),
            maxPendingTimers: cap
        )
        defer { session.close() }

        // The callbacks cannot run before this cell ends (it holds the JS
        // thread), so every timer stays pending. The last callback to run
        // settles `floodRan`.
        let flood = await session.evaluate(code: """
        let n = 0;
        globalThis.floodRan = new Promise((resolve) => {
          let ran = 0;
          try {
            for (let i = 0; i < \(2 * cap + 1); i++) { setTimeout(() => { if (++ran === n) resolve(ran); }, 0); n++; }
          } catch (e) {
            console.log(e.name, n);
          }
        });
        // The cell's value is not the promise, so the cell does not wait for it.
        undefined;
        """)
        #expect(flood.error == nil, "\(String(describing: flood.error))")
        #expect(flood.lines.map(\.text) == ["RangeError \(cap)"])

        // Settles once every callback ran; the cell's own timeout is the only bound.
        let ran = await session.evaluate(code: "console.log(await globalThis.floodRan)")
        #expect(ran.error == nil, "\(String(describing: ran.error))")
        #expect(ran.lines.map(\.text).last == "\(cap)")

        // Once those callbacks ran, every slot is free again: the session
        // takes `cap` timers (none of which comes due) once more.
        let refill = await session.evaluate(code: """
        const ids = [];
        for (let i = 0; i < \(cap); i++) ids.push(setTimeout(() => {}, 3600000));
        ids.forEach(clearTimeout);
        console.log(ids.length);
        """)
        #expect(refill.error == nil, "\(String(describing: refill.error))")
        #expect(refill.lines.map(\.text).last == "\(cap)")
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

    /// Output that reaches the native print past what the session keeps in
    /// memory goes to a spill file, but the runtime's output gate is not the
    /// only way there (the runtime's own error reports, a script holding the
    /// host): the spill stops at 64 MiB per cell and counts against the
    /// session's fs budget, so a script cannot fill the disk through it.
    @Test("Native output past the spill ceiling is dropped instead of written")
    func nativeSpillIsBounded() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-spill-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: scratch + "/work", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let session = BrowserReplSession(
            id: "spill-\(UUID().uuidString)",
            cwd: scratch + "/work",
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "resources.js", source: resourceRuntime)], agentScripts: []),
            driver: HeldCookiesDriver(),
            temporaryDirectory: scratch
        )
        defer { session.close() }

        // 112 MiB straight to the native host: 16 MiB kept, the rest spilled.
        let result = await browserReplWithDeadline(seconds: 180) {
            await session.evaluate(code: """
            const line = "x".repeat(1 << 20);
            for (let i = 0; i < 112; i++) native.print("log", line);
            native.print("log", "last");
            """, timeout: .seconds(170))
        }
        let lines = try #require(result?.lines)
        let continues = try #require(lines.first { $0.text.hasPrefix("# output continues in ") }?.text)
        let path = String(continues.dropFirst("# output continues in ".count))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber).intValue
        #expect(size <= 64 << 20, "the spill file grew to \(size) bytes")
        #expect(lines.contains { $0.text.contains("dropped") }, "\(lines.suffix(3).map(\.text))")
    }

    /// A page controls its events (console messages, errors, requests),
    /// and they queue for the session's thread while it is busy. They are
    /// bounded where they arrive, by count and bytes, not only once they
    /// wait for the callback budget, so a page cannot fill memory with them.
    @Test("Page events queued for a busy session are bounded by bytes where they arrive")
    func queuedPageEventsAreBounded() async throws {
        let driver = RecordingReplDriver()
        let runtime = resourceRuntime + #"""
        globalThis.__cmuxHostOnEvent = (name, payload) => { globalThis.eventCount = (globalThis.eventCount || 0) + 1; };
        """#
        let session = BrowserReplSession(
            id: "events-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "events.js", source: runtime)], agentScripts: []),
            driver: driver
        )
        defer { session.close() }
        // The first cell makes the context and attaches the driver's events.
        #expect(await session.evaluate(code: "globalThis.eventCount = 0;").error == nil)

        let busy = DispatchSemaphore(value: 0)
        #expect(session.thread.perform { busy.wait() })
        let payload = "\"" + String(repeating: "x", count: 1 << 20) + "\""
        for _ in 0..<100 { driver.emit("console", payload) }
        busy.signal()

        // A driver call's result follows the events that arrived before it.
        let result = await session.evaluate(code: "await driverOnce('tabs.list'); console.log(globalThis.eventCount);")
        let texts = result.lines.map(\.text)
        let delivered = Int(texts.last ?? "") ?? -1
        #expect(delivered >= 1 && delivered <= 64, "\(delivered) of 100 one-MiB events were queued: \(texts)")
        #expect(texts.contains { $0.contains("page events were dropped") }, "\(texts)")
    }

    /// A page controls its events' size, and the session masks secrets in
    /// each before agent code sees it. That work must not hold the session's
    /// JavaScript thread: a cell started meanwhile runs.
    @Test("Masking secrets in a page event does not hold up the session's cells")
    func eventRedactionRunsOffTheJavaScriptThread() async throws {
        let driver = SlowRedactionDriver()
        let session = makeSession(driver)
        defer {
            driver.releaseRedaction()
            session.close()
        }
        #expect(await session.evaluate(code: "1;").error == nil)

        driver.armBlockingRedaction()
        driver.emit("console", #"{"targetId":"t1","type":"log","text":"page text"}"#)
        await driver.waitUntilBlocked()
        let result = await session.evaluate(code: "console.log(1 + 1);", timeout: .seconds(5))
        driver.releaseRedaction()

        #expect(result.error == nil, "\(result.error ?? "")")
        #expect(result.lines.map(\.text) == ["2"])
        #expect(driver.blockedThreadName != "com.cmux.browser-repl.\(session.id)", "the event was masked on the session's thread")
    }

    /// Events are masked off the session's thread, but an event the driver
    /// sent before a call returned still reaches the runtime first: the
    /// runtime acts on it (a cancelled navigation fails the action that
    /// caused it) when the call's result arrives.
    @Test("An event sent before a driver call returns reaches the runtime before the call's result")
    func eventsStayAheadOfLaterResults() async throws {
        let driver = SlowRedactionDriver()
        let runtime = resourceRuntime + #"""
        globalThis.events = [];
        globalThis.__cmuxHostOnEvent = (name, payload) => { globalThis.events.push(JSON.parse(payload).text); };
        """#
        let session = BrowserReplSession(
            id: "ordered-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "ordered.js", source: runtime)], agentScripts: []),
            driver: driver
        )
        defer {
            driver.releaseRedaction()
            session.close()
        }
        #expect(await session.evaluate(code: "globalThis.events = [];").error == nil)

        async let evaluated = session.evaluate(
            code: "await driverOnce('emitThenReturn'); console.log(JSON.stringify(globalThis.events));",
            timeout: .seconds(30)
        )
        await driver.waitUntilBlocked()
        driver.releaseRedaction()
        let result = await evaluated

        #expect(result.error == nil, "\(result.error ?? "")")
        #expect(result.lines.map(\.text) == [#"["before the result"]"#])
    }

    /// Masking secrets can grow an event many times over (a mask is longer
    /// than a one-character value), so the bytes events hold while they wait
    /// for the session's thread are counted as they will reach JavaScript:
    /// an event whose masked payload would pass the budget arrives withheld.
    @Test("Page events waiting for a busy session are bounded by their masked size")
    func maskedPageEventsAreBounded() async throws {
        let driver = RecordingReplDriver()
        let runtime = resourceRuntime + #"""
        globalThis.seen = { bytes: 0, withheld: 0 };
        globalThis.__cmuxHostOnEvent = (name, payload) => {
          globalThis.seen.bytes += payload.length;
          if (JSON.parse(payload).withheld) globalThis.seen.withheld += 1;
        };
        """#
        let session = BrowserReplSession(
            id: "masked-events-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "events.js", source: runtime)], agentScripts: []),
            driver: driver
        )
        defer { session.close() }
        let armed = await session.evaluate(code: #"native.secrets("set", JSON.stringify({ name: "s", value: "q", domains: ["example.com"] }));"#)
        #expect(armed.error == nil, "\(armed.error ?? "")")

        // Each event is 800 KiB, the secret in every other byte, under the
        // 1 MiB per-event limit; masked, each grows to about 4.4 MiB, twenty
        // of them past 64 MiB.
        let busy = DispatchSemaphore(value: 0)
        #expect(session.thread.perform { busy.wait() })
        let text = String(repeating: "q ", count: 400 << 10)
        for _ in 0..<20 { driver.emit("console", #"{"targetId":"t1","type":"log","text":"\#(text)"}"#) }
        // Every event is masked and waiting for the thread before it runs again.
        session.eventQueue.sync {}
        busy.signal()

        let result = await session.evaluate(code: "await driverOnce('tabs.list'); console.log(JSON.stringify(globalThis.seen));")
        let seen = JSONSerialization.browserReplObject(result.lines.last?.text ?? "{}")
        let bytes = (seen["bytes"] as? NSNumber)?.intValue ?? -1
        let withheld = (seen["withheld"] as? NSNumber)?.intValue ?? -1
        #expect(bytes > 0 && bytes <= BrowserReplSession.maxQueuedEventBytes, "\(bytes) bytes of masked events waited at once")
        #expect(withheld >= 1, "\(result.lines.map { $0.text.prefix(200) })")
    }

    /// A driver call's parameters wait in the session's queue, or with the
    /// driver, until the call ends; one call's parameters are bounded where
    /// it is made, and so are those all its waiting and running calls hold.
    @Test("A driver call's parameters are bounded per call and across the calls a session holds")
    func driverCallParametersAreBounded() async throws {
        let driver = HeldCookiesDriver()
        let runtime = resourceRuntime + #"""
        globalThis.driverWith = (method, params) => new Promise((resolve, reject) => {
          const id = nextCall++; pending.set(id, { resolve, reject });
          __cmuxNative.driverCall(id, method, params);
        });
        """#
        let session = BrowserReplSession(
            id: "params-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "params.js", source: runtime)], agentScripts: []),
            driver: driver
        )
        defer {
            session.close()
            driver.releaseAll()
        }
        let result = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: """
            const big = JSON.stringify({ pad: "x".repeat(65 << 20) });
            const oversized = await driverWith("tabs.list", big).then(() => "ran", (e) => e.message);
            console.log(oversized);
            // Held by the driver: 60 MiB each, past 512 MiB on the ninth.
            const held = JSON.stringify({ pad: "x".repeat(60 << 20) });
            const outcomes = [];
            for (let i = 0; i < 9; i++) driverWith("cookies.get", held).then(() => {}, (e) => outcomes.push(e.message));
            await Promise.resolve();
            console.log(outcomes.length, outcomes[0]);
            """, timeout: .seconds(100))
        }
        let lines = result?.lines.map { String($0.text.prefix(300)) } ?? []
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        #expect(lines.first?.contains("MiB") == true && lines.first?.contains("ran") == false, "\(lines)")
        #expect(lines.last?.hasPrefix("1 ") == true && lines.last?.contains("MiB") == true, "\(lines)")
    }

    /// An event larger than the per-event limit arrives without its
    /// content, as other outputs past their limits do, and still names its
    /// tab, so masking never has to read it.
    @Test("A page event past the per-event limit arrives withheld, naming its tab")
    func oversizedEventIsWithheld() async throws {
        let driver = RecordingReplDriver()
        let runtime = resourceRuntime + #"""
        globalThis.events = [];
        globalThis.__cmuxHostOnEvent = (name, payload) => { globalThis.events.push([name, JSON.parse(payload)]); };
        """#
        let session = BrowserReplSession(
            id: "events-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "events.js", source: runtime)], agentScripts: []),
            driver: driver
        )
        defer { session.close() }
        #expect(await session.evaluate(code: "globalThis.events = [];").error == nil)
        let text = String(repeating: "x", count: 1 << 20)
        driver.emit("console", #"{"targetId":"t1","type":"log","text":"\#(text)"}"#)
        driver.emit("console", #"{"targetId":"t1","type":"log","text":"small"}"#)

        let result = await session.evaluate(code: """
        await driverOnce("tabs.list");
        console.log(JSON.stringify(globalThis.events.map(([name, p]) => [name, p.targetId, p.text ?? null, typeof p.withheld])));
        """)
        let shown = try #require(result.lines.last?.text)
        #expect(shown == #"[["console","t1",null,"string"],["console","t1","small","undefined"]]"#, "\(shown.prefix(300))")
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

    /// Cells run one at a time; callers that share a session wait for the
    /// running one. The waiting cells and their source are bounded, so a
    /// caller past either bound gets an error at once instead of waiting.
    @Test("A session holds at most 64 waiting cells; one more is refused at once")
    func waitingCellsAreBounded() async {
        let driver = HeldCookiesDriver()
        let session = makeSession(driver)
        defer {
            session.close()
            driver.releaseAll()
        }
        let running = Task { await session.evaluate(code: "await driverOnce('cookies.get'); console.log('first');", timeout: .seconds(60)) }
        let started = await browserReplWithDeadline(seconds: 30) { await driver.waitForEntries(1) }
        #expect(started != nil)

        let waiting = 64  // the documented bound
        let (results, sink) = AsyncStream.makeStream(of: BrowserReplEvalResult.self)
        for _ in 0...waiting {
            Task { sink.yield(await session.evaluate(code: "console.log('ran');", timeout: .seconds(60))) }
        }
        // The running cell holds every other one, so the first result is
        // the refusal of the one past the bound.
        let first = await browserReplWithDeadline(seconds: 30) { () -> BrowserReplEvalResult? in
            for await result in results { return result }
            return nil
        }
        #expect(first??.error?.contains("64 cells are already waiting") == true, "\(String(describing: first))")

        driver.releaseAll()
        #expect(await running.value.lines.map(\.text) == ["first"])
        let rest = await browserReplWithDeadline(seconds: 60) { () -> [BrowserReplEvalResult] in
            var collected: [BrowserReplEvalResult] = []
            for await result in results {
                collected.append(result)
                if collected.count == waiting { break }
            }
            return collected
        }
        #expect(rest?.count == waiting)
        #expect(rest?.allSatisfy { $0.error == nil && $0.lines.map(\.text) == ["ran"] } == true)
    }

    @Test("Cells waiting to run hold at most 64 MiB of source; more is refused at once")
    func waitingCellSourceIsBounded() async {
        let driver = HeldCookiesDriver()
        let session = makeSession(driver)
        defer {
            session.close()
            driver.releaseAll()
        }
        let running = Task { await session.evaluate(code: "await driverOnce('cookies.get');", timeout: .seconds(60)) }
        let started = await browserReplWithDeadline(seconds: 30) { await driver.waitForEntries(1) }
        #expect(started != nil)

        let large = "//" + String(repeating: "x", count: 64 << 20)
        let refused = await browserReplWithDeadline(seconds: 30) { await session.evaluate(code: large, timeout: .seconds(60)) }
        #expect(refused?.error?.contains("64 MiB") == true, "\(String(describing: refused?.error))")
        driver.releaseAll()
        _ = await running.value
    }

    @Test("A cell that times out cancels the driver calls it started")
    func timeoutCancelsTheCellsDriverCalls() async {
        let driver = HeldCookiesDriver()
        let session = makeSession(driver)
        defer {
            session.close()
            driver.releaseAll()
        }

        let result = await session.evaluate(
            code: "driverOnce('cookies.get'); await new Promise(() => {});",
            timeout: .milliseconds(100)
        )
        #expect(result.error?.contains("timed out") == true)

        // The call is still held by the driver; the timeout cancels it, not close().
        let cancelled = await browserReplWithDeadline(seconds: 10) { await driver.waitForCancellation() }
        #expect(cancelled != nil, "the timed-out cell's driver call kept running")
        #expect(!session.isClosed)
    }

    @Test("A session runs at most 256 driver calls at once; the rest start as earlier ones finish")
    func driverCallConcurrencyIsBounded() async {
        let completed = BrowserReplResponseCounter()
        let held = HeldCookiesDriver(responses: { completed.count })
        let session = makeSession(BrowserReplCountingDriver(held, completed: completed))
        defer {
            session.close()
            held.releaseAll()
        }

        let evaluation = Task {
            await session.evaluate(code: """
            const all = await Promise.all(Array.from({ length: 300 }, () => driverOnce("cookies.get")));
            console.log(all.length);
            """, timeout: .seconds(60))
        }
        let started = await browserReplWithDeadline(seconds: 30) { await held.waitForEntries(256) }
        #expect(started != nil)
        held.releaseAll()
        let result = await browserReplWithDeadline(seconds: 60) { await evaluation.value }

        #expect(result?.error == nil, "\(String(describing: result?.error))")
        #expect(result?.lines.map(\.text) == ["300"])
        // The 257th call starts only after one has finished, the 258th after two, and so on.
        let arrivals = held.responsesAtEntry
        #expect(arrivals.count == 300)
        for (index, finished) in arrivals.enumerated() where index >= 256 {
            #expect(finished >= index - 255, "driver call \(index + 1) started after \(finished) finished")
        }
    }

    @Test("A fetch past the queue bound fails at once with an error that says why")
    func fetchQueueIsBounded() async {
        let driver = HeldCookiesDriver()
        let session = makeSession(driver)
        defer {
            session.close()
            driver.releaseAll()
        }

        // The first 16 wait for their cookies in the running slots, the next
        // ones wait in the queue; past its bound a fetch fails at once.
        let admitted = BrowserReplSession.maxConcurrentFetches + 256  // the documented queue bound
        let result = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: """
            const all = Array.from({ length: \(admitted + 5) }, () => fetchOnce("http://127.0.0.1:9/held").then(() => "ok", (e) => e.message));
            const refused = await Promise.all(all.slice(\(admitted)));
            console.log(refused.length);
            console.log(refused[0]);
            """, timeout: .seconds(10))
        }
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        #expect(result?.lines.first?.text == "5")
        #expect(result?.lines.last?.text.contains("fetches are already waiting") == true, "\(String(describing: result?.lines))")
    }

    @Test("Fetches whose headers arrived and whose bodies never end do not hold the running slots")
    func streamingFetchesReleaseTheirSlots() async throws {
        let streams = try await (0..<4).asyncMap { _ in try await BrowserReplHeldResponseServer.started(bodyPrefix: Data(repeating: 0x61, count: 1024)) }
        defer { streams.forEach { $0.stop() } }
        let plain = try BrowserReplTestHTTPServer { _, _, _ in (200, ["Content-Type": "text/plain"], Data("ok".utf8)) }
        try await plain.start()
        defer { plain.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let session = makeSession(driver)
        defer { session.close() }

        // 16 fetches of event streams nobody awaits (four per server, under
        // URLSession's six connections per host).
        let urls = streams.flatMap { server in (0..<4).map { "\"http://127.0.0.1:\(server.port)/stream?\($0)\"" } }
        let started = await session.evaluate(code: "[\(urls.joined(separator: ","))].forEach((url) => fetchOnce(url).catch(() => {}));")
        #expect(started.error == nil)

        let next = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: "console.log((await fetchOnce('http://127.0.0.1:\(plain.port)/')).status)", timeout: .seconds(15))
        }
        #expect(next?.error == nil, "\(String(describing: next?.error))")
        #expect(next?.lines.map(\.text) == ["200"])
    }

    @Test("The response bodies a session's fetches buffer at once are bounded")
    func fetchBodyBuffersAreBoundedPerSession() async throws {
        // Three bodies of 50 MiB each fit the per-fetch limit; together they
        // pass the session's budget, so one fails while the others still wait.
        let chunk = Data(repeating: 0x62, count: 50 << 20)
        let server = try await BrowserReplHeldResponseServer.started(bodyPrefix: chunk, declaredLength: 60 << 20)
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let session = makeSession(driver)
        defer { session.close() }

        let result = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: """
            const all = [0, 1, 2].map((i) => fetchOnce("http://127.0.0.1:\(server.port)/body?" + i).then(() => "ok", (e) => e.message));
            console.log(await Promise.race(all));
            """, timeout: .seconds(60))
        }
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        #expect(result?.lines.first?.text.contains("hold more than 128 MiB") == true, "\(String(describing: result?.lines))")
    }
    /// A page value a driver call returns (`frame.evaluate`, a capture) is
    /// built by the page; past what one call may return it fails before
    /// the session masks or queues it.
    @Test("A driver result past 64 MiB fails with an error that says why")
    func oversizedDriverResultFails() async throws {
        let driver = LargeResultDriver(resultCharacters: 65 << 20)
        driver.releaseAll()
        let session = makeSession(driver)
        defer { session.close() }
        let result = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: """
            console.log(await driverOnce("big").then((r) => "returned " + r.length, (e) => e.message));
            """, timeout: .seconds(100))
        }
        let text = result?.lines.first?.text ?? ""
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        #expect(text.contains("64 MiB") && !text.hasPrefix("returned"), "\(text.prefix(300))")
    }

    /// Results a busy JavaScript thread has not taken yet stay with the
    /// session; together they hold at most 512 MiB, and one past it fails
    /// instead of waiting. Each result is reserved before it is masked, and
    /// the driver counts the maskings, so every reservation is made before
    /// the thread runs again.
    @Test("Driver results waiting for a busy session are bounded together")
    func waitingDriverResultsAreBounded() async throws {
        let driver = LargeResultDriver(resultCharacters: 60 << 20)
        let runtime = resourceRuntime + #"""
        globalThis.settled = null;
        """#
        let session = BrowserReplSession(
            id: "results-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "results.js", source: runtime)], agentScripts: []),
            driver: driver
        )
        defer {
            driver.releaseAll()
            session.close()
        }
        // Nine results of 60 MiB: eight fit in 512 MiB, the ninth does not.
        let started = await session.evaluate(code: """
        globalThis.settled = Promise.all(Array.from({ length: 9 }, () =>
          driverOnce("big").then((r) => "ok " + r.length, (e) => e.message)));
        """)
        #expect(started.error == nil, "\(started.error ?? "")")
        #expect(await browserReplWithDeadline(seconds: 30) { await driver.waitForEntries(9) } != nil)

        let busy = DispatchSemaphore(value: 0)
        #expect(session.thread.perform { busy.wait() })
        driver.countRedactions()
        driver.releaseAll()
        let masked = await browserReplWithDeadline(seconds: 60) { await driver.waitForRedactions(9) }
        busy.signal()
        #expect(masked != nil)

        let result = await browserReplWithDeadline(seconds: 120) {
            await session.evaluate(code: "console.log(JSON.stringify(await globalThis.settled));", timeout: .seconds(100))
        }
        let outcomes = (try? JSONSerialization.jsonObject(with: Data((result?.lines.first?.text ?? "[]").utf8))) as? [String] ?? []
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        #expect(outcomes.count == 9, "\(outcomes.map { $0.prefix(200) })")
        #expect(outcomes.filter { $0 == "ok \(60 << 20)" }.count == 8, "\(outcomes.map { $0.prefix(200) })")
        #expect(outcomes.filter { $0.contains("512 MiB") }.count == 1, "\(outcomes.map { $0.prefix(200) })")
    }
}

/// Answers `big` with a JSON string of `resultCharacters` characters once
/// `releaseAll()` ran (one shared string, so the test holds one copy), and
/// counts the maskings the session asks it for after `countRedactions()`.
final class LargeResultDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let result: String
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var entries = 0
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var counting = false
    private var redactions = 0
    private var redactionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(resultCharacters: Int) {
        result = "\"" + String(repeating: "r", count: resultCharacters) + "\""
    }

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        guard method == "big" else { return .success("null") }
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            entries += 1
            let satisfied = entryWaiters.filter { $0.count <= entries }.map(\.continuation)
            entryWaiters.removeAll { $0.count <= entries }
            return satisfied
        }
        for waiter in ready { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if released { return true }
                held.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
        return .success(result)
    }

    func waitForEntries(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if entries >= count { return true }
                entryWaiters.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func releaseAll() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { held.removeAll() }
            return held
        }
        for continuation in pending { continuation.resume() }
    }

    func countRedactions() { lock.withLock { counting = true } }

    func waitForRedactions(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if redactions >= count { return true }
                redactionWaiters.append((count, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func typedSecretRedaction() -> BrowserReplSecretStore? {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard counting else { return [] }
            redactions += 1
            let satisfied = redactionWaiters.filter { $0.count <= redactions }.map(\.continuation)
            redactionWaiters.removeAll { $0.count <= redactions }
            return satisfied
        }
        for waiter in ready { waiter.resume() }
        return nil
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}
}

/// Answers every request with its headers and the first part of a body,
/// then holds the connection open until `stop()`, like an event stream or
/// a slow download.
final class BrowserReplHeldResponseServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.browser-repl.test-held-http")
    private let bodyPrefix: Data
    private let declaredLength: Int
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    private init(bodyPrefix: Data, declaredLength: Int) throws {
        self.bodyPrefix = bodyPrefix
        self.declaredLength = declaredLength
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func started(bodyPrefix: Data, declaredLength: Int? = nil) async throws -> BrowserReplHeldResponseServer {
        let server = try BrowserReplHeldResponseServer(bodyPrefix: bodyPrefix, declaredLength: declaredLength ?? (bodyPrefix.count + (1 << 20)))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = BrowserReplOnceBox<Void>()
            box.set(continuation)
            server.listener.stateUpdateHandler = { [weak server] state in
                if case .ready = state {
                    server?.port = server?.listener.port?.rawValue ?? 0
                    box.resume(())
                }
            }
            server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock {
            defer { connections.removeAll() }
            return connections
        }
        for connection in open { connection.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if !done { self.receive(connection, buffer: buffer) }
                return
            }
            var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(self.declaredLength)\r\n\r\n".utf8)
            out.append(self.bodyPrefix)
            connection.send(content: out, completion: .contentProcessed { _ in })
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
