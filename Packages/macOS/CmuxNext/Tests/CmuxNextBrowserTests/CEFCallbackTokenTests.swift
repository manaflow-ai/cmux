import AppKit
import CmuxNextCompat
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The shim's callbacks get the runtime's ``CEFRuntime/callbacks`` token as their context,
/// never the runtime's address, so a context that names no live runtime finds nothing instead of being read as
/// one (Chromium's MiraclePtr property, applied to C callback contexts). Run under `--sanitize=address` and
/// `--sanitize=thread` too.
@MainActor @Suite(.serialized)
struct CEFCallbackTokenTests {
    @Test func aNullContextFindsNoRuntime() {
        #expect(CEFRuntime.from(0) == nil)
        #expect(CEFRuntime.pumpGate(at: 0) == nil)
    }

    @Test func aLiveTokenFindsItsRuntimeAndItsGate() throws {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let token = try CEFRuntime.callbacks.register(runtime)
        defer { CEFRuntime.callbacks.unregister(token) }
        #expect(CEFRuntime.from(token.rawValue) === runtime)
        #expect(CEFRuntime.pumpGate(at: token.rawValue) === runtime.pumpGate, "the Chromium-thread path resolves the same way")
    }

    @Test func anUnregisteredTokenFindsNothingAndIsCounted() throws {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let token = try CEFRuntime.callbacks.register(runtime)
        #expect(CEFRuntime.callbacks.unregister(token))
        let before = CEFRuntime.callbacks.ignoredCount
        // Before the registry, these read a CEFRuntime at the context's address, live or not.
        #expect(CEFRuntime.from(token.rawValue) == nil, "a stale generation finds nothing, though the runtime lives")
        #expect(CEFRuntime.pumpGate(at: token.rawValue) == nil)
        #expect(CEFRuntime.callbacks.ignoredCount == before + 2)
        withExtendedLifetime(runtime) {}
    }

    @Test func aTokenWhoseRuntimeIsGoneFindsNothing() throws {
        var runtime: CEFRuntime? = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let token = try CEFRuntime.callbacks.register(try #require(runtime))
        defer { CEFRuntime.callbacks.unregister(token) }
        runtime = nil
        #expect(CEFRuntime.from(token.rawValue) == nil, "a runtime that went without unregistering is never handed back")
        #expect(CEFRuntime.pumpGate(at: token.rawValue) == nil)
    }

    @Test func aScheduleRequestWithAStaleContextReachesNoPump() throws {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let token = try CEFRuntime.callbacks.register(runtime)
        CEFRuntime.callbacks.unregister(token)
        let before = CEFRuntime.callbacks.ignoredCount
        // On the main thread the request is delivered in the call: it resolves the context, finds nothing, returns.
        // SAFETY: only the token's bits reach the callback.
        unsafe cefScheduleCallback(token.context, 0)
        #expect(CEFRuntime.callbacks.ignoredCount == before + 1)
        withExtendedLifetime(runtime) {}
    }

    /// Chromium threads keep asking for pump work with the live token while the main thread unregisters it and
    /// drops the runtime: no request reads a freed runtime (ASan and TSan stay quiet), and every request after
    /// the close is ignored and counted.
    @Test func scheduleRequestsDuringCloseReachNoFreedRuntime() async throws {
        var runtime: CEFRuntime? = CEFRuntime(storage: CEFProfileStorage(root: Self.scratch()))
        let token = try Self.registerKeepingRequests(try #require(runtime))
        let bits = token.rawValue
        let schedule = cefScheduleCallback
        let before = CEFRuntime.callbacks.ignoredCount
        let chaos = CallbackChaos(threads: 4, afterClose: 250)
        await chaos.start {
            // SAFETY: only the token's bits reach the callback.
            unsafe schedule(UnsafeMutableRawPointer(bitPattern: bits), Self.laterThanTheArmedFire)
        }
        #expect(CEFRuntime.callbacks.unregister(token))
        runtime = nil
        await chaos.close()
        #expect(CEFRuntime.callbacks.ignoredCount - before >= UInt64(chaos.threads * chaos.afterClose),
                "every request after the close was ignored and counted")
        #expect(CEFRuntime.pumpGate(at: bits) == nil)
    }

    /// A request delay (ms) past the fire ``registerKeepingRequests(_:)`` arms.
    private nonisolated static let laterThanTheArmedFire: Int64 = 7_200_000

    /// Registers `runtime` and arms its gate an hour out, so the gate keeps every request for later work: the
    /// live phase of the chaos case posts nothing to the main run loop, and after the close each request is
    /// a lookup that misses.
    private static func registerKeepingRequests(_ runtime: CEFRuntime) throws(CallbackRegistryError) -> CallbackToken {
        let token = try CEFRuntime.callbacks.register(runtime)
        runtime.pumpGate.publish(deadlineNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 3_600_000_000_000)
        return token
    }

    @Test func aParentViewIsTheViewsOwnAddress() {
        let view = NSView()
        // SAFETY: compares the two addresses only.
        #expect(unsafe CEFParentView(view: view).pointer == Unmanaged.passUnretained(view).toOpaque())
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cef-callback-token-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

/// Real threads that fire one C callback with one context while the test closes the context's owner (the
/// close-during-callback chaos case): each thread fires once, keeps firing until ``close()``, then fires
/// `afterClose` more times, which all come after the close.
nonisolated private final class CallbackChaos: Sendable {
    let threads: Int
    let afterClose: Int
    private let closed = Atomic<Bool>(false)
    private let warm = DispatchGroup()
    private let done = DispatchGroup()
    private let notifyQueue = DispatchQueue(label: "cmux.test.callback-chaos", qos: .userInitiated)

    init(threads: Int, afterClose: Int) {
        self.threads = threads
        self.afterClose = afterClose
    }

    /// Starts the threads and returns once each has fired, so the close overlaps live callbacks.
    func start(_ fire: @escaping @Sendable () -> Void) async {
        for index in 0..<threads {
            warm.enter()
            done.enter()
            let thread = Thread { [self] in
                fire()
                warm.leave()
                while !closed.load(ordering: .acquiring) { fire() }
                for _ in 0..<afterClose { fire() }
                done.leave()
            }
            thread.name = "cmux-callback-chaos-\(index)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        await withCheckedContinuation { continuation in warm.notify(queue: notifyQueue) { continuation.resume() } }
    }

    /// Call after the owner is closed: each thread fires `afterClose` more times; returns when all are done.
    func close() async {
        closed.store(true, ordering: .releasing)
        await withCheckedContinuation { continuation in done.notify(queue: notifyQueue) { continuation.resume() } }
    }
}
