import Darwin
import Foundation

/// One other thread's stack at the moment a main-thread hang was reported.
public struct ThreadSample: Sendable {
    /// The thread's name (`pthread_setname_np`, as the kernel holds it); empty when unnamed.
    public var name: String
    /// Return addresses, innermost first.
    public var addresses: [UInt]
}

extension ThreadStackSampler {
    /// The most threads one hang report samples (Chromium runs about 60).
    static let otherThreadLimit = 128

    /// Samples every thread of this process except `excluded` (the main thread) and the
    /// calling thread, one at a time. Watchdog thread only, after the main thread's own sample.
    ///
    /// A main thread that waits on a lock (`__ulock_wait2` in dyld's loader lock, an allocator
    /// lock) or on a reply shows only the wait; the thread that holds the lock is among these.
    /// Each thread is suspended only while its frames are walked into a preallocated buffer
    /// (``sample(whileSuspended:)``), so no thread is stopped while this code allocates.
    static func sampleOtherThreads(excluding excluded: thread_act_t, maxFrames: Int = 48) -> [ThreadSample] {
        // SAFETY: pthread_self is the calling thread's own pthread, live while it runs; only its port is read.
        let current = unsafe pthread_mach_thread_np(pthread_self())
        // SAFETY: the ports are read only inside the closure, while withTaskThreads holds the list it releases after.
        return unsafe MachThreads.withTaskThreads { threads in
            var samples: [ThreadSample] = []
            for thread in threads where samples.count < otherThreadLimit {
                guard thread != excluded, thread != current else { continue }
                let name = MachThreads.name(thread)
                let addresses = ThreadStackSampler(thread: thread, maxFrames: maxFrames).sample()
                guard !addresses.isEmpty else { continue }
                samples.append(ThreadSample(name: name, addresses: addresses))
            }
            return samples
        }
    }
}
