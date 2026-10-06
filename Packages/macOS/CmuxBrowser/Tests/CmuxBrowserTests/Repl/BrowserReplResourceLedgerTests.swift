import Foundation
import Testing

@testable import CmuxBrowser

/// A minimal runtime over the native host, as in the session resource tests.
private let ledgerRuntime = #"""
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
const driverWith = (method, params) => new Promise((resolve, reject) => {
  const id = nextCall++; pending.set(id, { resolve, reject });
  __cmuxNative.driverCall(id, method, params === undefined ? "{}" : params);
});
const sleep = (ms) => new Promise((r) => { const id = nextTimer++; timers.set(id, r); __cmuxNative.setTimer(id, ms, false); });
const console = { log: (...a) => __cmuxNative.print("log", a.map(String).join(" ")) };
const AsyncFunction = (async () => {}).constructor;
globalThis.__cmuxFormatError = (e) => `${e.name}: ${e.message}`;
globalThis.__cmuxReplEval = (code) =>
  new AsyncFunction("console", "fetchOnce", "driverWith", "sleep", "native", code)(console, fetchOnce, driverWith, sleep, __cmuxNative);
"""#

/// Holds `hold` calls, and `cookies.get` for URLs that contain `held` (the
/// fetcher's first step), until `releaseAll()` or cancellation; answers
/// everything else at once. `emit` sends a page event.
final class LedgerWorkloadDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var sink: BrowserReplDriverEventSink?

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        let holds = method == "hold" || (method == "cookies.get" && paramsJSON.contains("held"))
        guard holds else { return .success(method == "cookies.get" ? "[]" : "null") }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock {
                    if released || Task.isCancelled { return true }
                    held[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { held.removeValue(forKey: id) }?.resume()
        }
        return .success(method == "cookies.get" ? "[]" : "null")
    }

    func releaseAll() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { held.removeAll() }
            return Array(held.values)
        }
        for continuation in pending { continuation.resume() }
    }

    func emit(_ name: String, _ payload: String) {
        lock.withLock { sink }?(name, payload)
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) { lock.withLock { sink = eventSink } }
    func detach() { lock.withLock { sink = nil } }
}

/// Waits until `condition` holds, or `seconds` pass; returns whether it held.
private func browserReplEventually(seconds: Double = 30, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

extension BrowserReplResourceLimits {
    /// These limits with every byte limit divided by `divisor`, so a test
    /// reaches them without allocating hundreds of MiB.
    func dividingBytes(by divisor: Int) -> Self {
        BrowserReplResource.allCases.filter(\.isBytes).reduce(self) { limits, resource in
            var scaled = limits.with(resource, limits[resource] == .max ? .max : limits[resource] / divisor)
            if let each = limits.each(resource) { scaled = scaled.with(resource, each: each / divisor) }
            return scaled
        }
    }
}

@Suite("Browser REPL resource ledger", .serialized)
struct BrowserReplResourceLedgerTests {
    @Test("A reservation past a limit is refused whole, with one message that names the limit")
    func refusalsNameTheLimit() {
        let ledger = BrowserReplResourceLedger(limits: BrowserReplResourceLimits.unbounded
            .with(.queuedFetches, 2)
            .with(.driverResultBytes, 3 << 20)
            .with(.driverResultBytes, each: 2 << 20))
        #expect(ledger.reserve(2, of: .queuedFetches) == nil)
        let full = ledger.reserve(1, of: .queuedFetches)
        #expect(full?.message == "REPL session limit: fetches waiting for a slot at most 2 at once (2 held, this needs 1 more); await some before starting more")
        #expect(ledger.held(.queuedFetches) == 2)

        let one = ledger.reserve(5 << 20, of: .driverResultBytes)
        #expect(one?.isPerItem == true)
        #expect(one?.message.contains("at most 2 MiB each (this one is 5 MiB)") == true, "\(one?.message ?? "")")
        #expect(ledger.reserve(2 << 20, of: .driverResultBytes) == nil)
        #expect(ledger.reserve(2 << 20, of: .driverResultBytes)?.message.contains("at most 3 MiB at once") == true)
        // A resize that does not fit keeps what was held.
        #expect(ledger.resize(.driverResultBytes, from: 2 << 20, to: 4 << 20, each: .max) != nil)
        #expect(ledger.held(.driverResultBytes) == 2 << 20)

        ledger.release(2, of: .queuedFetches)
        ledger.release(2 << 20, of: .driverResultBytes)
        #expect(ledger.outstanding.isEmpty)
    }

    @Test("Lifetime limits are spent, not held")
    func lifetimeLimitsAreSpent() {
        let ledger = BrowserReplResourceLedger(limits: BrowserReplResourceLimits.unbounded.with(.fileEntryChanges, 2))
        #expect(ledger.reserve(2, of: .fileEntryChanges) == nil)
        ledger.release(2, of: .fileEntryChanges)
        #expect(ledger.reserve(1, of: .fileEntryChanges)?.message.contains("over the session's life") == true)
        #expect(ledger.outstanding.isEmpty)
    }

    /// Every resource is reserved by a session holder in a workload that
    /// uses them all, and once the session is closed every reservation is
    /// released. A resource no holder reserves fails the first check; a
    /// holder that reserves and never releases fails the second.
    @Test("Every holder reserves from the session's ledger, and everything is released after the session ends")
    func everyHolderReservesAndReleases() async throws {
        let stream = try await BrowserReplHeldResponseServer.started(bodyPrefix: Data(repeating: 0x61, count: 2048))
        defer { stream.stop() }
        let driver = LedgerWorkloadDriver()
        let session = BrowserReplSession(
            id: "ledger-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "ledger.js", source: ledgerRuntime)], agentScripts: []),
            driver: driver,
            limits: BrowserReplResourceLimits.standard
                .with(.runningDriverCalls, 1)
                .with(.requestPhaseFetches, 1)
                .with(.retainedOutputBytes, 4096),
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
        let ledger = session.ledger
        defer { driver.releaseAll() }

        // A fetch whose body is arriving, then one held before its
        // headers and one waiting for that slot; a call that runs and
        // returns, one held running and one waiting for its slot; a timer;
        // output past the in-memory limit; an fs change.
        let started = await session.evaluate(code: """
        fetchOnce("http://127.0.0.1:\(stream.port)/stream").catch(() => {});
        await driverWith("tabs.list");
        await driverWith("input.drag", JSON.stringify({ path: [{ x: 0, y: 0 }, { x: 9, y: 9 }] }));
        driverWith("hold").catch(() => {});
        driverWith("tabs.list").catch(() => {});
        sleep(600000);
        console.log("kept");
        console.log("x".repeat(8192));
        native.fs("mkdir", JSON.stringify({ path: native.tmpdir + "/ledger" }));
        """)
        #expect(started.error == nil, "\(started.error ?? "")")
        #expect(await browserReplEventually { ledger.held(.fetchBodyBytes) > 0 }, "the streaming fetch never held its body")
        let queued = await session.evaluate(code: """
        fetchOnce("http://127.0.0.1:\(stream.port)/held?1").catch(() => {});
        fetchOnce("http://127.0.0.1:\(stream.port)/held?2").catch(() => {});
        """)
        #expect(queued.error == nil, "\(queued.error ?? "")")
        driver.emit("console", #"{"targetId":"t1","type":"log","text":"an event"}"#)

        // A cell that runs until the session closes, and one waiting for it
        // (submitted once the first holds the session, so it is second).
        let beforeRunning = session.lastUsed
        Task { _ = await session.evaluate(code: "await new Promise(() => {});") }
        #expect(await browserReplEventually { session.lastUsed > beforeRunning }, "the running cell never started")
        #expect(await browserReplEventually { ledger.held(.queuedFetches) == 1 }, "the second held fetch never waited for a slot")
        Task { _ = await session.evaluate(code: "console.log('waited');") }
        #expect(await browserReplEventually { ledger.held(.waitingCells) == 1 }, "the second cell never waited")

        // Held events need callbacks in debt between cells, and secrets
        // file protections a secrets file in the working directory; their
        // bounds have their own tests (secretSourceFilesAreBoundedPerSession);
        // typed domain sets need a typed secret
        // (typedDomainSetsAreCanonicalAndBounded); only the process-wide
        // ledger holds processMemoryBytes (BrowserReplProcessBudgetTests).
        let unused = BrowserReplResource.allCases.filter { ![.heldEvents, .secretSourceFiles, .typedDomainSets, .processMemoryBytes].contains($0) && ledger.peak($0) == 0 }
        #expect(unused.isEmpty, "no holder reserved \(unused)")

        session.close()
        driver.releaseAll()
        #expect(await browserReplEventually { ledger.outstanding.isEmpty }, "still held after the session ended: \(ledger.outstanding)")
    }

    /// Each holder has its own limit, and the session also has one for
    /// all it holds in memory together, 512 MiB (decided 2026-10-04). The
    /// limits are divided by 64: eight calls hold 450 KiB of parameters
    /// each while their 900 KiB results wait for a busy thread. Each
    /// holder stays under its own limit (8 MiB), but together they would
    /// hold 10.8 MiB, past the session's 8 MiB.
    @Test("What a session holds in memory is bounded together, not only per holder")
    func sessionMemoryIsBoundedTogether() async throws {
        let divisor = 64
        let sessionLimit = (512 << 20) / divisor
        let resultBytes = 900 << 10
        let paramsBytes = 450 << 10
        let driver = LargeResultDriver(resultCharacters: resultBytes - 2)
        let session = BrowserReplSession(
            id: "memory-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "memory.js", source: ledgerRuntime)], agentScripts: []),
            driver: driver,
            limits: BrowserReplResourceLimits.standard.dividingBytes(by: divisor),
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
        defer {
            driver.releaseAll()
            session.close()
        }
        let started = await session.evaluate(code: """
        const pad = JSON.stringify({ pad: "p".repeat(\(paramsBytes - 12)) });
        globalThis.settled = Promise.all(Array.from({ length: 8 }, () =>
          driverWith("big", pad).then((r) => "ok", (e) => e.message)));
        """)
        #expect(started.error == nil, "\(started.error ?? "")")
        #expect(await browserReplWithDeadline(seconds: 30) { await driver.waitForEntries(8) } != nil)

        // The results arrive while the session's thread is busy, so they wait.
        let busy = DispatchSemaphore(value: 0)
        #expect(session.thread.perform { busy.wait() })
        driver.countRedactions()
        driver.releaseAll()
        let masked = await browserReplWithDeadline(seconds: 60) { await driver.waitForRedactions(8) }
        busy.signal()
        #expect(masked != nil)

        let result = await browserReplWithDeadline(seconds: 60) {
            await session.evaluate(code: "console.log(JSON.stringify(await globalThis.settled));")
        }
        let outcomes = (try? JSONSerialization.jsonObject(with: Data((result?.lines.first?.text ?? "[]").utf8))) as? [String] ?? []
        #expect(outcomes.count == 8, "\(outcomes)")
        let admitted = outcomes.filter { $0 == "ok" }.count
        #expect(8 * paramsBytes + admitted * resultBytes <= sessionLimit, "\(admitted) results of \(resultBytes) bytes waited beside \(8 * paramsBytes) bytes of parameters")
        #expect(outcomes.contains { $0.contains("REPL session limit: memory the session holds") && $0.contains("8 MiB") }, "\(outcomes)")
    }
    /// A session whose JavaScript heap limit is lowered to 64 MiB.
    private func heapSession(id: String = "heap-\(UUID().uuidString)") -> BrowserReplSession {
        BrowserReplSession(
            id: id,
            cwd: browserReplTestWorkingDirectory,
            bundle: BrowserReplRuntimeBundle(replScripts: [.init(name: "heap.js", source: ledgerRuntime)], agentScripts: []),
            driver: LedgerWorkloadDriver(),
            limits: BrowserReplResourceLimits.standard.with(.scriptHeapBytes, 64 << 20),
            executionTimeLimitSupported: BrowserReplWatchdog.isSupported
        )
    }

    /// What agent code keeps reachable between cells is the session's
    /// memory: each cell here keeps 16 MiB more, so by the fifth the
    /// session's heap is past its 64 MiB and the session ends, saying why.
    /// Garbage is not counted: a cell that makes 256 MiB and keeps none of
    /// it runs.
    @Test("JavaScript a session keeps between cells is bounded, and past the limit the session ends")
    func javaScriptHeapIsBounded() async throws {
        let session = heapSession()
        defer { session.close() }

        let garbage = await session.evaluate(code: "for (let i = 0; i < 64; i++) { const s = 'g'.repeat(4 << 20) + i; } console.log('made');")
        #expect(garbage.error == nil, "\(garbage.error ?? "")")

        var errors: [String?] = []
        for _ in 0..<8 {
            let kept = await browserReplWithDeadline(seconds: 60) {
                await session.evaluate(code: "(globalThis.keep ??= []).push('k'.repeat(16 << 20) + keep.length); console.log(keep.length);")
            }
            errors.append(kept == nil ? "timed out" : kept?.error)
            if kept?.error != nil { break }
        }
        let ended = errors.compactMap { $0 }.first ?? ""
        #expect(ended.contains("JavaScript heap") && ended.contains("at most 64 MiB"), "\(errors)")
        #expect(errors.count <= 5, "\(errors.count) cells kept 16 MiB each")
        #expect(await browserReplEventually { session.isClosed })
    }

    /// Timers keep running between cells, so the heap is also measured
    /// after their runs. The session they push past its limit ends, and
    /// the next session of that name says why the last one did.
    @Test("JavaScript kept by timers between cells is bounded too, and the next session of that name says why the last ended")
    func javaScriptHeapBetweenCellsIsBounded() async throws {
        let registry = BrowserReplSessionRegistry()
        let key = BrowserReplSessionKey(workspaceID: UUID(), name: "heap")
        let first = try registry.session(for: key) { heapSession(id: $0) }
        defer { first.close() }

        // 4 MiB every 50 ms after the cell ends, 256 MiB at most.
        let started = await first.evaluate(code: """
        globalThis.keep = [];
        (async () => { for (let i = 0; i < 64; i++) { await sleep(50); keep.push('t'.repeat(4 << 20) + i); } })();
        console.log('started');
        """)
        #expect(started.error == nil, "\(started.error ?? "")")
        #expect(await browserReplEventually(seconds: 20) { first.isClosed }, "the session kept growing between cells")

        let second = try registry.session(for: key) { heapSession(id: $0) }
        defer { second.close() }
        #expect(second !== first)
        let next = await second.evaluate(code: "console.log('fresh');")
        #expect(next.error == nil, "\(next.error ?? "")")
        let text = next.lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("JavaScript heap") && text.contains("at most 64 MiB"), "\(text)")
        #expect(text.contains("fresh"))
    }
    /// A fetch's body reaches the session's JavaScript as Base64 in a JSON
    /// result, a third larger than the bytes that arrived; that result is
    /// what waits for the session's thread, so that is what the ledger
    /// holds, and a result past the limit is refused.
    @Test("A fetch's body is held at the size of the result that carries it")
    func fetchBodiesAreHeldAtTheirResultSize() async throws {
        let server = try BrowserReplTestHTTPServer { path, _, _ in
            (200, ["Content-Type": "application/octet-stream"], Data(repeating: 0x61, count: path == "/large" ? 900 << 10 : 600 << 10))
        }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let ledger = BrowserReplResourceLedger(limits: BrowserReplResourceLimits.unbounded.with(.fetchBodyBytes, 1 << 20).with(.fetchBodyBytes, each: 1 << 20))
        let fetcher = BrowserReplFetcher(driver: driver, ledger: ledger)
        defer { fetcher.invalidate() }
        func request(_ path: String) -> String {
            JSONSerialization.browserReplString(["url": "http://127.0.0.1:\(server.port)\(path)", "credentials": "omit"]) ?? "{}"
        }

        let (small, held) = await fetcher.fetchHoldingBody(requestJSON: request("/small"), onResponse: nil)
        guard case .success(let json) = small else {
            Issue.record("the 600 KiB fetch failed: \(small)")
            return
        }
        #expect(held >= json.utf8.count, "\(held) bytes held for a \(json.utf8.count)-byte result")
        #expect(ledger.held(.fetchBodyBytes) == held)
        fetcher.bodyBudget.release(held)

        // 900 KiB arrives within the 1 MiB limit; its 1.2 MiB result does not fit.
        let (large, largeHeld) = await fetcher.fetchHoldingBody(requestJSON: request("/large"), onResponse: nil)
        if case .failure(let error) = large {
            #expect(error.message.contains("REPL session limit: response bodies the session's fetches hold"), "\(error.message)")
        } else {
            Issue.record("a 900 KiB body was held as a \(largeHeld)-byte result within a 1 MiB limit")
        }
        fetcher.bodyBudget.release(largeHeld)
        #expect(ledger.held(.fetchBodyBytes) == 0)
    }
}
