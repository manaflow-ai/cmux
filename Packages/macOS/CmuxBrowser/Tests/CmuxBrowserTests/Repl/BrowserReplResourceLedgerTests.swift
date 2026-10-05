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

        // A cell that runs until the session closes, and one waiting for it.
        Task { _ = await session.evaluate(code: "await new Promise(() => {});") }
        #expect(await browserReplEventually { ledger.held(.queuedFetches) == 1 }, "the second held fetch never waited for a slot")
        Task { _ = await session.evaluate(code: "console.log('waited');") }
        #expect(await browserReplEventually { ledger.held(.waitingCells) == 1 }, "the second cell never waited")

        // Held events need callbacks in debt between cells; their bound has its own test.
        let unused = BrowserReplResource.allCases.filter { $0 != .heldEvents && ledger.peak($0) == 0 }
        #expect(unused.isEmpty, "no holder reserved \(unused)")

        session.close()
        driver.releaseAll()
        #expect(await browserReplEventually { ledger.outstanding.isEmpty }, "still held after the session ended: \(ledger.outstanding)")
    }
}
