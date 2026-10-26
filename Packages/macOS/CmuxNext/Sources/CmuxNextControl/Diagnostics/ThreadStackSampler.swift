import Darwin
import Foundation

/// Samples another thread's stack by suspending it and walking its frame
/// pointer chain. Used only from the watchdog thread.
///
/// Between `thread_suspend` and `thread_resume` the code must not allocate
/// or take locks the target might hold (malloc, the Swift runtime): it
/// writes into a preallocated buffer and reads memory with
/// `vm_read_overwrite`, which fails safely on a bad pointer.
// crash-allow: the buffer is written only while the target thread is suspended and read only after the sample is published; no lock may be taken while the target is suspended
final class ThreadStackSampler: @unchecked Sendable {
    let thread: thread_act_t
    let maxFrames: Int
    // The watchdog thread writes the buffer while the target is suspended.
    // The target reads it (``copy(count:)``) only after a sample was
    // published for its current stall, and the next sample waits for that
    // stall to end, so the two never overlap.
    private let buffer: UnsafeMutablePointer<UInt>

    init(thread: thread_act_t, maxFrames: Int = 64) {
        self.thread = thread
        self.maxFrames = maxFrames
        // SAFETY: a fresh allocation of maxFrames words, freed once in deinit; store writes only indices under
        // maxFrames and copy reads only the first min(count, maxFrames) of them.
        buffer = unsafe UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
    }

    deinit {
        // SAFETY: the allocation of init; nothing else holds `self` any more.
        unsafe buffer.deallocate()
    }

    /// Return addresses, innermost first. Empty when the thread could not be
    /// suspended or its state could not be read.
    func sample() -> [UInt] {
        sample { _ in }
    }

    /// Same as ``sample()``, and runs `whileSuspended` with the frame count
    /// before the thread resumes. `whileSuspended` must not allocate or take
    /// a lock (atomics only): the suspended thread may hold them.
    func sample(whileSuspended: (Int) -> Void) -> [UInt] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let count = walk()
        whileSuspended(count)
        thread_resume(thread)
        return copy(count: count)
    }

    /// Writes one frame when `index` is inside the buffer. Pointer arithmetic
    /// and `pointee` are transparent, so the suspended section makes no runtime
    /// call and no allocation (a generic accessor could, at -Onone).
    private func store(_ address: UInt, at index: Int) {
        guard index >= 0, index < maxFrames else { return }
        // SAFETY: 0 <= index < maxFrames (checked above), the buffer's capacity; UInt needs no initialization.
        let slot = unsafe buffer + index
        unsafe slot.pointee = address
    }

    /// The first `count` addresses of the last sample.
    func copy(count: Int) -> [UInt] {
        // SAFETY: at most maxFrames words, the buffer's capacity, which walk() wrote for this sample (`count` is the
        // frame count it returned); no sample writes meanwhile (the type's note).
        unsafe Array(UnsafeBufferPointer(start: buffer, count: min(max(count, 0), maxFrames)))
    }

    /// Caller has suspended the thread. No allocation in here.
    private func walk() -> Int {
        var pc: UInt = 0
        var fp: UInt = 0
        var lr: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        // SAFETY: thread_get_state writes at most `count` natural_t words, the size of `state` (a local live for the
        // call), and the count it wrote into `count`; the words are the thread state's own layout.
        let result = unsafe withUnsafeMutablePointer(to: &state) {
            unsafe $0.withMemoryRebound(to: natural_t.self, capacity: Int(clamping: count)) {
                unsafe thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(clamping: state.__pc)
        fp = UInt(clamping: state.__fp)
        lr = UInt(clamping: state.__lr)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        // SAFETY: as for arm64 above.
        let result = unsafe withUnsafeMutablePointer(to: &state) {
            unsafe $0.withMemoryRebound(to: natural_t.self, capacity: Int(clamping: count)) {
                unsafe thread_get_state(thread, x86_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(clamping: state.__rip)
        fp = UInt(clamping: state.__rbp)
        #endif
        var frames = 0
        store(Self.strip(pc), at: frames)
        frames += 1
        if lr != 0, frames < maxFrames {
            store(Self.strip(lr), at: frames)
            frames += 1
        }
        var pair: (UInt, UInt) = (0, 0)
        while fp != 0, fp & 0x7 == 0, frames < maxFrames {
            var size: vm_size_t = 0
            // SAFETY: vm_read_overwrite copies exactly the size of `pair` (two words, a local live for the call) into it
            // and fails, without a fault, when `fp` is not readable; it writes the size it copied into `size`.
            let read = unsafe withUnsafeMutablePointer(to: &pair) { pointer in
                unsafe vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                         vm_address_t(UInt(bitPattern: pointer)), &size)
            }
            guard read == KERN_SUCCESS else { break }
            let (next, returnAddress) = pair
            guard returnAddress != 0 else { break }
            store(Self.strip(returnAddress), at: frames)
            frames += 1
            // Frames grow toward higher addresses; anything else is a loop or garbage.
            guard next > fp else { break }
            fp = next
        }
        return frames
    }

    /// Drops pointer-authentication bits (arm64e system frameworks).
    private static func strip(_ address: UInt) -> UInt {
        address & 0x0000_7FFF_FFFF_FFFF
    }
}
