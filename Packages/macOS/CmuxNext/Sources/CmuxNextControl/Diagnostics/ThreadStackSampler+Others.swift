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
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        let threads = UnsafeBufferPointer(start: list, count: Int(truncatingIfNeeded: count))
        defer {
            for thread in threads { mach_port_deallocate(mach_task_self_, thread) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(truncatingIfNeeded: threads.count * MemoryLayout<thread_act_t>.stride))
        }
        let current = pthread_mach_thread_np(pthread_self())
        var samples: [ThreadSample] = []
        for thread in threads where samples.count < otherThreadLimit {
            guard thread != excluded, thread != current else { continue }
            let name = threadName(thread)
            let addresses = ThreadStackSampler(thread: thread, maxFrames: maxFrames).sample()
            guard !addresses.isEmpty else { continue }
            samples.append(ThreadSample(name: name, addresses: addresses))
        }
        return samples
    }

    /// The kernel's copy of the thread's name (`THREAD_EXTENDED_INFO`), with no pthread lock.
    private static func threadName(_ thread: thread_act_t) -> String {
        var info = thread_extended_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(truncatingIfNeeded: count)) {
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "" }
        return withUnsafeBytes(of: &info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
