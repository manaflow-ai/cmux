import CmuxSafeConcurrency
import Dispatch
import Testing

/// A shared home for a mutex, so that threads can reach the same one (a `Mutex` is not copyable).
private final class Shared<Value: Sendable>: Sendable {
    let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }
}

private struct Failure: Error, Equatable {
    let code: Int
}

/// A value that cannot be copied, to prove `Mutex` holds one.
private struct Token: ~Copyable {
    var uses = 0
}

/// Records the observer's calls in order. `waitWillBegin` runs `onWait` first (the test lets the holder
/// release the lock there, so the wait is real and ends).
private final class RecordingObserver: MutexWaitObserver, Sendable {
    let events = Mutex<[String]>([])
    let observes: Bool
    let onWait: @Sendable () -> Void

    init(observes: Bool = true, onWait: @escaping @Sendable () -> Void = {}) {
        self.observes = observes
        self.onWait = onWait
    }

    func waitWillBegin() -> Int? {
        events.withLock { $0.append("will") }
        onWait()
        return observes ? 7 : nil
    }

    func waitDidEnd(_ wait: Int) -> String? {
        events.withLock { $0.append("did \(wait)") }
        return "report \(wait)"
    }

    func lockReleased(_ report: String) {
        events.withLock { $0.append("released \(report)") }
    }

    var recorded: [String] {
        events.withLock { $0 }
    }
}

/// Holds `shared`'s lock on another thread until `release()`; `init` returns once the lock is held.
private final class Holder: Sendable {
    private let held = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)

    init(_ shared: Shared<Int>) {
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

@Suite struct MutexTests {
    @Test func withLockChangesTheValueAndReturnsTheResult() {
        let mutex = Mutex(1)
        let result = mutex.withLock { value -> Int in
            value += 41
            return value * 2
        }
        #expect(result == 84)
        #expect(mutex.withLock { $0 } == 42)
    }

    @Test func withLockPassesATypedErrorThrough() {
        let mutex = Mutex(0)
        #expect(throws: Failure(code: 3)) {
            try mutex.withLock { (value: inout Int) throws(Failure) -> Void in
                value = 9
                throw Failure(code: 3)
            }
        }
        #expect(mutex.withLock { $0 } == 9)
    }

    @Test func itHoldsANoncopyableValue() {
        let mutex = Mutex(Token())
        mutex.withLock { $0.uses += 1 }
        mutex.withLock { $0.uses += 1 }
        #expect(mutex.withLock { $0.uses } == 2)
    }

    @Test func withLockIfAvailableRunsWhenTheLockIsFree() {
        let mutex = Mutex(5)
        #expect(mutex.withLockIfAvailable { $0 + 1 } == 6)
    }

    @Test func withLockIfAvailableReturnsNilWhileTheLockIsHeld() {
        let mutex = Mutex(5)
        let ranInside = mutex.withLock { _ in mutex.withLockIfAvailable { _ in true } ?? false }
        #expect(!ranInside)
        let shared = Shared(5)
        let holder = Holder(shared)
        #expect(shared.mutex.withLockIfAvailable { $0 } == nil)
        holder.release()
        holder.finish()
        #expect(shared.mutex.withLockIfAvailable { $0 } == 105)
    }

    @Test func concurrentChangesAreSerialized() {
        let shared = Shared(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            for _ in 0..<1_000 {
                shared.mutex.withLock { $0 += 1 }
            }
        }
        #expect(shared.mutex.withLock { $0 } == 64_000)
    }

    @Test func anUncontendedObservedLockCallsNoObserver() {
        let mutex = Mutex(0)
        let observer = RecordingObserver()
        mutex.withLock(observedBy: observer) { $0 += 1 }
        #expect(observer.recorded.isEmpty)
        #expect(mutex.withLock { $0 } == 1)
    }

    @Test func aContendedWaitIsObservedAndReportedAfterTheUnlock() {
        let shared = Shared(0)
        let holder = Holder(shared)
        let observer = RecordingObserver(onWait: { holder.release() })
        let seenInBody = shared.mutex.withLock(observedBy: observer) { value -> [String] in
            value += 1
            return observer.recorded
        }
        holder.finish()
        #expect(seenInBody == ["will", "did 7"])
        #expect(observer.recorded == ["will", "did 7", "released report 7"])
        #expect(shared.mutex.withLock { $0 } == 101)
    }

    @Test func aWaitTheObserverDeclinesIsNotReported() {
        let shared = Shared(0)
        let holder = Holder(shared)
        let observer = RecordingObserver(observes: false, onWait: { holder.release() })
        shared.mutex.withLock(observedBy: observer) { $0 += 1 }
        holder.finish()
        #expect(observer.recorded == ["will"])
        #expect(shared.mutex.withLock { $0 } == 101)
    }

    @Test func concurrentObservedChangesAreSerialized() {
        let shared = Shared(0)
        let observer = RecordingObserver(observes: false)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            for _ in 0..<1_000 {
                shared.mutex.withLock(observedBy: observer) { $0 += 1 }
            }
        }
        #expect(shared.mutex.withLock { $0 } == 32_000)
        #expect(observer.recorded.allSatisfy { $0 == "will" })
    }
}

@Suite struct PlatformLockTests {
    /// State kept beside a lock, as a portable stand-in for a system lock type keeps it.
    private final class Counter: @unchecked Sendable { // crash-allow: `count` is read and written only under `lock`
        let lock = PlatformLock()
        var count = 0
    }

    @Test func withLockSerializesStateBesideTheLock() {
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            for _ in 0..<1_000 {
                counter.lock.withLock { counter.count += 1 }
            }
        }
        #expect(counter.lock.withLock { counter.count } == 64_000)
    }

    @Test func withLockIfAvailableReturnsNilWhileTheLockIsHeld() {
        let lock = PlatformLock()
        let ranInside = lock.withLock { lock.withLockIfAvailable { true } ?? false }
        #expect(!ranInside)
        #expect(lock.withLockIfAvailable { 2 } == 2)
    }

    @Test func withLockPassesATypedErrorThrough() {
        let lock = PlatformLock()
        #expect(throws: Failure(code: 4)) {
            try lock.withLock { () throws(Failure) -> Void in throw Failure(code: 4) }
        }
        #expect(lock.withLockIfAvailable { true } == true)
    }
}

/// Taking a lock again on the thread that holds it stops the process instead of hanging it: os_unfair_lock
/// traps on Apple platforms, and the Debug error-checking pthread mutex returns EDEADLK elsewhere, which
/// fails the lock's check (Chromium's base/synchronization/lock_impl_posix.cc checks the same error).
#if canImport(os) || DEBUG
@Suite struct LockMisuseTests {
    @Test func takingAMutexAgainInsideItsBodyStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            let mutex = Mutex(0)
            mutex.withLock { _ in mutex.withLock { $0 += 1 } }
        }
    }

    @Test func takingAPlatformLockAgainInsideItsBodyStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            let lock = PlatformLock()
            lock.withLock { lock.withLock {} }
        }
    }
}
#endif
