import CmuxSafeConcurrency
@testable import CmuxThreading
import Dispatch
import Testing

private struct Failure: Error, Equatable {
    let code: Int
}

/// Records what the hook is asked, in order. `lockWaitWillBegin` runs `onWait` first (the test lets the holder
/// release the lock there, so the wait is real and ends).
private final class RecordingHook: BlockingCallHook {
    let events = CmuxSafeConcurrency.Mutex<[String]>([])
    let times: Bool
    let onWait: @Sendable () -> Void

    init(times: Bool = true, onWait: @escaping @Sendable () -> Void = {}) {
        self.times = times
        self.onWait = onWait
    }

    func blockingCall<Result, Failure: Error>(
        _ kind: BlockingKind, fileID: StaticString, line: UInt, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        events.withLock { $0.append("call \(kind.rawValue) \(fileID):\(line)") }
        return try body()
    }

    func lockWaitWillBegin() -> UInt64? {
        events.withLock { $0.append("will") }
        onWait()
        return times ? 10 : nil
    }

    func lockWaitDidEnd(startedAt start: UInt64) -> UInt64? {
        events.withLock { $0.append("did \(start)") }
        return start + 5
    }

    func lockWaited(fileID: StaticString, line: UInt, nanos: UInt64) {
        events.withLock { $0.append("waited \(fileID):\(line) \(nanos)") }
    }

    var recorded: [String] {
        events.withLock { $0 }
    }
}

/// A shared home for a portable mutex, so that threads can reach the same one.
private final class Shared: Sendable {
    let mutex = CmuxSafeConcurrency.Mutex(0)
}

/// Holds `shared`'s lock on another thread until `release()`; `init` returns once the lock is held.
private final class Holder: Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)

    init(_ shared: Shared) {
        let held = held, releaseSignal = releaseSignal, done = done
        DispatchQueue.global(qos: .userInitiated).async { // qos-allow: test fixture thread that holds the lock
            shared.mutex.withLock { value in
                held.signal()
                releaseSignal.wait() // blocking-allow: test fixture: the holder waits for the test to release it
                value += 100
            }
            done.signal()
        }
        held.wait() // blocking-allow: test fixture: wait until the other thread holds the lock
    }

    func release() {
        releaseSignal.signal()
    }

    func finish() {
        done.wait() // blocking-allow: test fixture: join the holder thread
    }
}

@Suite struct BlockingCallHookSlotTests {
    @Test func theFirstInstallStaysAndARepeatIsRefused() {
        let slot = BlockingCallHookSlot()
        let first = RecordingHook(), second = RecordingHook()
        #expect(!slot.isInstalled)
        #expect(slot.install(first))
        #expect(!slot.install(second))
        #expect(slot.isInstalled)
        _ = slot.blockingCall(.sqlite, fileID: "Pkg/Store.swift", line: 9) { 1 }
        #expect(first.recorded == ["call sqlite Pkg/Store.swift:9"])
        #expect(second.recorded.isEmpty)
    }

    @Test func aCallGoesThroughTheHookWithItsKindAndSite() {
        let slot = BlockingCallHookSlot()
        let hook = RecordingHook()
        slot.install(hook)
        let result = slot.blockingCall(.fileIO, fileID: "Pkg/Reader.swift", line: 42) { 7 * 6 }
        #expect(result == 42)
        #expect(hook.recorded == ["call file-io Pkg/Reader.swift:42"])
    }

    @Test func withoutAHookACallIsItsBody() {
        let slot = BlockingCallHookSlot()
        #expect(slot.blockingCall(.socketRead) { "read" } == "read")
    }

    @Test func aTypedErrorPassesThroughWithAndWithoutAHook() {
        let empty = BlockingCallHookSlot()
        #expect(throws: Failure(code: 1)) {
            try empty.blockingCall(.processWait) { () throws(Failure) -> Int in throw Failure(code: 1) }
        }
        let hooked = BlockingCallHookSlot()
        hooked.install(RecordingHook())
        #expect(throws: Failure(code: 2)) {
            try hooked.blockingCall(.processWait) { () throws(Failure) -> Int in throw Failure(code: 2) }
        }
    }

    @Test func theFreeFunctionRunsItsBodyInAProcessWithNoHook() throws {
        // No test installs a hook into the process slot: a package's tests run as the iOS app does.
        #expect(!BlockingCallHookSlot.process.isInstalled)
        #expect(blockingCall(.fsMetadata) { 5 } == 5)
        #expect(throws: Failure(code: 3)) {
            try blockingCall(.fileIO) { () throws(Failure) -> Int in throw Failure(code: 3) }
        }
    }

    @Test func theKindsKeepTheAppsNames() {
        // The app's hook records a call under the app kind of the same raw value (CmuxNextCompat's BlockingKind).
        #expect(BlockingKind.allCases.map(\.rawValue) == [
            "file-io", "fs-metadata", "socket-read", "socket-write", "sync-wait", "ipc-reply", "process-wait",
            "process-spawn", "process-reap", "system-call", "system-query", "sqlite", "sleep",
        ])
    }
}

@Suite struct HookedMutexTests {
    @Test func withLockChangesTheValueAndReturnsTheResult() {
        let mutex = CmuxThreading.Mutex(1)
        let result = mutex.withLock { value -> Int in
            value += 41
            return value * 2
        }
        #expect(result == 84)
        #expect(mutex.withLock { $0 } == 42)
        #expect(mutex.withLockIfAvailable { $0 } == 42)
    }

    @Test func withLockIfAvailableReturnsNilInsideItsOwnLock() {
        let mutex = CmuxThreading.Mutex(5)
        #expect(mutex.withLock { _ in mutex.withLockIfAvailable { _ in true } ?? false } == false)
    }

    @Test func aContendedWaitIsTimedByTheHookAndReportedAfterTheUnlock() {
        let slot = BlockingCallHookSlot()
        let shared = Shared()
        let holder = Holder(shared)
        let hook = RecordingHook(onWait: { holder.release() })
        slot.install(hook)
        let wait = HookedLockWait(slot: slot, fileID: "Pkg/Cache.swift", line: 7)
        let seenInBody = shared.mutex.withLock(observedBy: wait) { value -> [String] in
            value += 1
            return hook.recorded
        }
        holder.finish()
        #expect(seenInBody == ["will", "did 10"])
        #expect(hook.recorded == ["will", "did 10", "waited Pkg/Cache.swift:7 15"])
        #expect(shared.mutex.withLock { $0 } == 101)
    }

    @Test func aWaitTheHookDoesNotTimeIsNotReported() {
        let slot = BlockingCallHookSlot()
        let shared = Shared()
        let holder = Holder(shared)
        let hook = RecordingHook(times: false, onWait: { holder.release() })
        slot.install(hook)
        shared.mutex.withLock(observedBy: HookedLockWait(slot: slot, fileID: "Pkg/Cache.swift", line: 8)) { $0 += 1 }
        holder.finish()
        #expect(hook.recorded == ["will"])
        #expect(shared.mutex.withLock { $0 } == 101)
    }

    @Test func aContendedWaitWithNoHookIsUntimed() {
        let shared = Shared()
        let holder = Holder(shared)
        let release = DispatchQueue(label: "com.cmuxterm.threading-tests.release", qos: .userInitiated)
        release.asyncAfter(deadline: .now() + .milliseconds(20)) { holder.release() }
        shared.mutex.withLock(observedBy: HookedLockWait(slot: BlockingCallHookSlot(), fileID: "Pkg/A.swift", line: 1)) {
            $0 += 1
        }
        holder.finish()
        #expect(shared.mutex.withLock { $0 } == 101)
    }

    @Test func concurrentChangesAreSerialized() {
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            for _ in 0..<1_000 {
                counter.mutex.withLock { $0 += 1 }
            }
        }
        #expect(counter.mutex.withLock { $0 } == 32_000)
    }

    private final class Counter: Sendable {
        let mutex = CmuxThreading.Mutex(0)
    }
}

/// Records the site and lane each item was posted with, and runs it at once.
private final class RecordingRunner: MayBlockRunner {
    let posts = CmuxSafeConcurrency.Mutex<[String]>([])

    private func record(_ lane: String, _ priority: MayBlockPriority, _ shutdown: MayBlockShutdown, _ site: MayBlockCallSite) {
        posts.withLock { $0.append("\(lane) \(priority) \(shutdown) \(site.fileID):\(site.line)") }
    }

    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        record("files", priority, shutdown, site)
        return try body()
    }

    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T {
        record("system", priority, shutdown, site)
        return try body()
    }

    func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T {
        record("resolve", priority, shutdown, site)
        return try body()
    }

    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                   _ body: @escaping @Sendable () -> Void) {
        record("post", priority, shutdown, site)
        body()
    }
}

@Suite struct MayBlockRunnerTests {
    @Test func theOverloadsPassTheCallersSiteAndDefaults() async throws {
        let runner = RecordingRunner()
        let line = #line + 1
        let read = try await runner.runFiles(.userVisible) { 3 }
        let resolved = try await runner.runHostResolution(.userBlocking, fileID: "Pkg/Dial.swift", line: 4) { "host" }
        let checked = try await runner.runSystem(.bestEffort, shutdown: .continueOnShutdown) { true }
        runner.postFiles(.idle, shutdown: .blockShutdown, fileID: "Pkg/Save.swift", line: 12) {}
        #expect(read == 3 && resolved == "host" && checked)
        let posts = runner.posts.withLock { $0 }
        #expect(posts == [
            "files userVisible skipOnShutdown CmuxThreadingTests/BlockingCallHookTests.swift:\(line)",
            "resolve userBlocking skipOnShutdown Pkg/Dial.swift:4",
            "system bestEffort continueOnShutdown CmuxThreadingTests/BlockingCallHookTests.swift:\(line + 2)",
            "post idle blockShutdown Pkg/Save.swift:12",
        ])
    }

    @Test func prioritiesAreOrderedAsChromesTaskPriority() {
        #expect(MayBlockPriority.allCases.sorted() == [.idle, .bestEffort, .userVisible, .userBlocking])
    }
}
