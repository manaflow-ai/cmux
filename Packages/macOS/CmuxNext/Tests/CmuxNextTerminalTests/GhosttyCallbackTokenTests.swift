import AppKit
import CmuxNextCompat
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// libghostty's runtime callbacks (`wakeup_cb`, `action_cb`, ...) get the runtime context's
/// ``RuntimeCallbackContext/callbacks`` token as their userdata, never the context's address, so a callback whose
/// context is unregistered or gone resolves to nothing instead of reading freed memory (Chromium's MiraclePtr
/// property, applied to C callback contexts). Run under `--sanitize=address` and `--sanitize=thread` too.
@MainActor @Suite(.serialized)
struct GhosttyCallbackTokenTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func theStartedRuntimesUserdataResolvesToItsOwnContext() throws {
        let runtime = GhosttyRuntime.startedForTests()
        let app = try #require(runtime.app, "libghostty made no app")
        // SAFETY: the shared runtime's live app; only its userdata's bits are read.
        let context = try #require(unsafe RuntimeCallbackContext.from(ghostty_app_userdata(app)))
        #expect(context.runtime === runtime)
    }

    @Test func aNullUserdataIsNoRuntimeContext() {
        // SAFETY: a NULL userdata; nothing is read through it.
        #expect(unsafe RuntimeCallbackContext.from(nil) == nil)
        unsafe ghosttyWakeup(nil)
    }

    @Test func anUnregisteredContextsTokenResolvesToNothingAndIsCounted() throws {
        let context = RuntimeCallbackContext()
        let token = try RuntimeCallbackContext.callbacks.register(context)
        // SAFETY: only the token's bits are read.
        #expect(unsafe RuntimeCallbackContext.from(token.context) === context)
        #expect(RuntimeCallbackContext.callbacks.unregister(token))
        let before = RuntimeCallbackContext.callbacks.ignoredCount
        // Before the registry, the wakeup read an atomic at whatever the userdata pointed at.
        // SAFETY: only the token's bits reach the callbacks.
        #expect(unsafe RuntimeCallbackContext.from(token.context) == nil, "a stale generation finds nothing, though the context lives")
        unsafe ghosttyWakeup(token.context)
        #expect(RuntimeCallbackContext.callbacks.ignoredCount == before + 2)
        // Read first: #expect would take the noncopyable Atomic itself as its operand.
        let pending = context.pending.load(ordering: .relaxed)
        #expect(!pending, "the stale wakeup reached no context")
    }

    @Test func aContextThatIsGoneResolvesToNothingAndItsWakeupIsIgnored() throws {
        let token = try registeredContextThatThenGoes()
        defer { RuntimeCallbackContext.callbacks.unregister(token) }
        let before = RuntimeCallbackContext.callbacks.ignoredCount
        // SAFETY: only the token's bits reach the callbacks.
        #expect(unsafe RuntimeCallbackContext.from(token.context) == nil, "a freed context is never handed back")
        unsafe ghosttyWakeup(token.context)
        #expect(RuntimeCallbackContext.callbacks.ignoredCount == before + 2)
    }

    /// A context checked to resolve while it lives; its last reference goes when this returns.
    private func registeredContextThatThenGoes() throws -> CallbackToken {
        let context = RuntimeCallbackContext()
        let token = try RuntimeCallbackContext.callbacks.register(context)
        // SAFETY: only the token's bits are read.
        #expect(unsafe RuntimeCallbackContext.from(token.context) === context)
        return token
    }

    /// The close-during-callback chaos case: libghostty's IO threads keep calling `wakeup_cb` with the live
    /// token while this thread unregisters it and drops the context. No wakeup reads a freed context (ASan and
    /// TSan stay quiet), and every wakeup after the close is ignored and counted. In this serialized suite, so
    /// no other test of the suite moves the registry's count meanwhile.
    @Test func wakeupsDuringCloseReachNoFreedContext() async throws {
        var context: RuntimeCallbackContext? = RuntimeCallbackContext()
        let token = try RuntimeCallbackContext.callbacks.register(try #require(context))
        let bits = token.rawValue
        let before = RuntimeCallbackContext.callbacks.ignoredCount
        let chaos = CallbackChaos(threads: 4, afterClose: 250)
        await chaos.start {
            // SAFETY: only the token's bits reach the callback.
            unsafe ghosttyWakeup(UnsafeMutableRawPointer(bitPattern: bits))
        }
        // The close, while the IO threads fire: the entry goes, then the last reference this test holds.
        #expect(RuntimeCallbackContext.callbacks.unregister(token))
        context = nil
        await chaos.close()
        #expect(context == nil)
        #expect(RuntimeCallbackContext.callbacks.ignoredCount - before >= UInt64(chaos.threads * chaos.afterClose),
                "every wakeup after the close was ignored and counted")
        // SAFETY: only the token's bits are read.
        #expect(unsafe RuntimeCallbackContext.from(UnsafeMutableRawPointer(bitPattern: bits)) == nil)
    }
}

/// Real threads that fire one C callback with one context while the test closes the context's owner: each
/// thread fires once, keeps firing until ``close()``, then fires `afterClose` more times, which all come after
/// the close.
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
