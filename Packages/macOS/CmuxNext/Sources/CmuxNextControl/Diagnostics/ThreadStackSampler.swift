import Darwin
import Foundation

/// Samples another thread's stack by suspending it and walking its frame
/// pointer chain. Used only from the watchdog thread.
///
/// Between `thread_suspend` and `thread_resume` the code must not allocate
/// or take a lock the target might hold (malloc, the Swift runtime). A Debug
/// build does not specialize generics, so the suspended section uses no
/// generic, tuple or imported C struct value at all: only buffers allocated
/// here, pointer arithmetic and `pointee` (transparent, inlined even at
/// -Onone) and the kernel calls `thread_get_state` and `vm_read_overwrite`
/// (which fails safely on a bad pointer). The walk once read the registers
/// through `withUnsafeMutablePointer` and a `(UInt, UInt)` tuple: in a Debug
/// build the process's first sample then filled the Swift runtime's metadata
/// caches under its locks, and when the suspended main thread held such a
/// lock at launch, the watchdog thread waited for it forever and never
/// resumed the main thread (STATUS 6990: the reopened app never answered).
final class ThreadStackSampler: @unchecked Sendable {
    let thread: thread_act_t
    let maxFrames: Int
    // The watchdog thread writes the buffer while the target is suspended.
    // The target reads it (``copy(count:)``) only after a sample was
    // published for its current stall, and the next sample waits for that
    // stall to end, so the two never overlap.
    private let buffer: UnsafeMutablePointer<UInt>
    /// The thread's registers as 64-bit words; `thread_get_state` (C) writes
    /// them through ``stateWords``, the same memory passed as its word type.
    private let registers: UnsafeMutablePointer<UInt>
    private let stateWords: thread_state_t
    private let stateCount: mach_msg_type_number_t
    private let flavor: thread_state_flavor_t
    /// Register indexes in ``registers`` (`lrIndex` -1: no link register).
    private let pcIndex: Int
    private let fpIndex: Int
    private let lrIndex: Int
    /// One frame record (saved frame pointer, return address), read with
    /// `vm_read_overwrite` into this preallocated pair.
    private let record: UnsafeMutablePointer<UInt>
    private let recordAddress: vm_address_t
    private let recordSize: vm_size_t
    /// This task's port, read here: a Debug build checks every read of the C global `mach_task_self_` for
    /// exclusive access (`swift_beginAccess`), a runtime call.
    private let task: vm_map_read_t

    init(thread: thread_act_t, maxFrames: Int = 64) {
        self.thread = thread
        self.maxFrames = maxFrames
        buffer = .allocate(capacity: maxFrames)
        // Everything the suspended section needs is made here, while no
        // thread is suspended: the buffers, the register layout and its size.
        let word = MemoryLayout<UInt>.size
        #if arch(arm64)
        let size = MemoryLayout<arm_thread_state64_t>.size
        flavor = ARM_THREAD_STATE64
        pcIndex = MemoryLayout<arm_thread_state64_t>.offset(of: \.__pc).map { $0 / word } ?? 32
        fpIndex = MemoryLayout<arm_thread_state64_t>.offset(of: \.__fp).map { $0 / word } ?? 29
        lrIndex = MemoryLayout<arm_thread_state64_t>.offset(of: \.__lr).map { $0 / word } ?? 30
        #elseif arch(x86_64)
        let size = MemoryLayout<x86_thread_state64_t>.size
        flavor = x86_THREAD_STATE64
        pcIndex = MemoryLayout<x86_thread_state64_t>.offset(of: \.__rip).map { $0 / word } ?? 16
        fpIndex = MemoryLayout<x86_thread_state64_t>.offset(of: \.__rbp).map { $0 / word } ?? 6
        lrIndex = -1
        #else
        #error("ThreadStackSampler reads arm64 or x86_64 registers only")
        #endif
        let words = (size + word - 1) / word
        registers = .allocate(capacity: words)
        registers.initialize(repeating: 0, count: words)
        // The kernel writes raw bytes; Swift reads them only as `UInt` (the memory's bound type).
        stateWords = thread_state_t(OpaquePointer(registers))
        stateCount = mach_msg_type_number_t(size / MemoryLayout<natural_t>.size)
        record = .allocate(capacity: 2)
        record.initialize(repeating: 0, count: 2)
        recordAddress = vm_address_t(UInt(bitPattern: record))
        recordSize = vm_size_t(2 * word)
        task = mach_task_self_
    }

    deinit {
        buffer.deallocate()
        registers.deallocate()
        record.deallocate()
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
        (buffer + index).pointee = address
    }

    /// The first `count` addresses of the last sample.
    func copy(count: Int) -> [UInt] {
        Array(UnsafeBufferPointer(start: buffer, count: min(max(count, 0), maxFrames)))
    }

    /// Caller has suspended the thread. No allocation, no lock and no Swift
    /// runtime call in here, in any build (the type comment says why).
    private func walk() -> Int {
        var count = stateCount
        guard thread_get_state(thread, flavor, stateWords, &count) == KERN_SUCCESS else { return 0 }
        var fp = (registers + fpIndex).pointee
        var frames = 0
        store(Self.strip((registers + pcIndex).pointee), at: frames)
        frames += 1
        if lrIndex >= 0, (registers + lrIndex).pointee != 0, frames < maxFrames {
            store(Self.strip((registers + lrIndex).pointee), at: frames)
            frames += 1
        }
        while fp != 0, fp & 0x7 == 0, frames < maxFrames {
            var size: vm_size_t = 0
            guard vm_read_overwrite(task, fp, recordSize, recordAddress, &size) == KERN_SUCCESS else { break }
            let next = record.pointee
            let returnAddress = (record + 1).pointee
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
