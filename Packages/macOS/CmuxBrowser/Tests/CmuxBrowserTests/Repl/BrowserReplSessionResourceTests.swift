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

/// Answers every call with `null` and records the methods it was asked.
final class RecordingDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var methods: [String] { lock.withLock { recorded } }
    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        lock.withLock { recorded.append(method) }
        return .success("null")
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}
}
