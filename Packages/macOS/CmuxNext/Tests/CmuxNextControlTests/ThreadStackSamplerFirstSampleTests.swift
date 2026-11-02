@testable import CmuxNextControl
import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing

/// The main-thread watchdog's sampler suspends a thread and walks its stack. Its FIRST sample in a process must
/// not wait for anything the suspended thread may hold.
///
/// A Debug build's walk called the Swift runtime while the thread was suspended: the foreign metadata of the
/// thread state, the `(UInt, UInt)` tuple metadata and unspecialized generics. The first call fills those
/// caches under the runtime's locks. When the suspended main thread held such a lock at launch, the watchdog
/// thread waited for it forever and never resumed the main thread: the reopened app hung with no log line and
/// no hang report (STATUS 6990: smoke relaunch on cmux24, 2026-11-02; the same signature on cmux18, 2026-10-31).
///
/// Each case is a fresh process (an exit test), so its sample is that process's first. A victim thread makes
/// new tuple types without end: each new type takes the runtime's tuple metadata lock and allocates. The sample
/// must come back; one that waits for the suspended victim never does, and the case exits 1 after its bound.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ThreadStackSamplerFirstSampleTests {
    @Test(arguments: 0..<24)
    func aProcessFirstSampleNeverWaitsForTheSuspendedThread(_ run: Int) async {
        _ = run  // one fresh process per case: the first sample's caches are cold in each
        await #expect(processExitsWith: .success) {
            FirstSampleProbe().sampleABusyVictim()
        }
    }
}

/// An empty type: tuples of it stay zero-sized however deep they nest.
private struct VictimSeed {}

/// The exit-test body: a victim that keeps the runtime's metadata locks busy, one sample of it, and the exit code
/// (0: the sample came back with the victim's frames; 1: it never came back; 2: it came back short, so the walk
/// lost the frame chain; 3: the victim never started).
final class FirstSampleProbe: @unchecked Sendable {
    private let port = Atomic<UInt32>(0)
    private let stop = Atomic<Bool>(false)
    private let busy = DispatchSemaphore(value: 0)
    private let sampled = DispatchSemaphore(value: 0)
    private let frames = Atomic<Int>(-1)

    func sampleABusyVictim() -> Never {
        let victim = Thread { [self] in
            port.store(mach_thread_self(), ordering: .releasing)
            nest(VictimSeed.self, depth: 0)
        }
        victim.stackSize = 1 << 30
        victim.start()
        guard busy.wait(timeout: .now() + .seconds(20)) == .success else { _exit(3) }
        let sampler = ThreadStackSampler(thread: port.load(ordering: .acquiring))
        // Bounded by its completion signal: a sampler that waits for the suspended victim never signals.
        let deadline = DispatchTime.now() + .seconds(5)
        let walker = Thread { [self] in
            frames.store(sampler.sample().count, ordering: .releasing)
            sampled.signal()
        }
        walker.start()
        // _exit, not exit: atexit work could need a lock the still-suspended victim holds.
        guard sampled.wait(timeout: deadline) == .success else { _exit(1) }
        stop.store(true, ordering: .releasing)
        // The victim is at least 256 frames deep: a walk that follows its frame chain fills the buffer.
        _exit(frames.load(ordering: .acquiring) >= 32 ? 0 : 2)
    }

    /// Each level asks the runtime for a new tuple type `(T, T)`: its metadata lock and an allocation.
    private func nest<T>(_ type: T.Type, depth: Int) {
        if depth == 256 { busy.signal() }
        guard depth < 2_000_000, !stop.load(ordering: .relaxed) else { return }
        nest((T, T).self, depth: depth + 1)
    }
}
