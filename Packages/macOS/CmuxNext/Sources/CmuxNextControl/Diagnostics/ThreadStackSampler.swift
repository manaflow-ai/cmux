import Darwin
import Foundation

/// Samples another thread's stack by suspending it and walking its frame
/// pointer chain. Used only from the watchdog thread.
///
/// Between `thread_suspend` and `thread_resume` the code must not allocate
/// or take a lock the target might hold (malloc, the Swift runtime). A Debug
/// build does not specialize generics, so the suspended section uses no
/// generic, tuple or imported C struct value at all: only buffers allocated
/// in init, pointer arithmetic and `pointee` (transparent, inlined even at
/// -Onone) and the kernel calls `thread_get_state` and `vm_read_overwrite`
/// (which fails safely on a bad pointer). The walk once read the registers
/// through `withUnsafeMutablePointer` and a `(UInt, UInt)` tuple: in a Debug
/// build the process's first sample then filled the Swift runtime's metadata
/// caches under its locks, and when the suspended main thread held such a
/// lock at launch, the watchdog thread waited for it forever and never
/// resumed the main thread (STATUS 6990; feat #32463).
// crash-allow: the buffer is written only while the target thread is suspended and read only after the sample is published; no lock may be taken while the target is suspended
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
        // SAFETY: a fresh allocation of maxFrames words, freed once in deinit; store writes only indices under
        // maxFrames and copy reads only the first min(count, maxFrames) of them.
        buffer = unsafe UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
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
        // SAFETY: `words` words cover the thread state's `size` bytes; freed once in deinit. The kernel writes raw
        // bytes through `stateWords`; Swift reads them only as `UInt`, the memory's bound type, at indexes under
        // `words` (pcIndex, fpIndex and lrIndex are offsets inside the state).
        registers = unsafe UnsafeMutablePointer<UInt>.allocate(capacity: words)
        unsafe registers.initialize(repeating: 0, count: words)
        stateWords = unsafe thread_state_t(OpaquePointer(registers))
        stateCount = mach_msg_type_number_t(size / MemoryLayout<natural_t>.size)
        // SAFETY: two words (saved frame pointer, return address), freed once in deinit; vm_read_overwrite writes
        // exactly recordSize (two words) bytes there.
        record = unsafe UnsafeMutablePointer<UInt>.allocate(capacity: 2)
        unsafe record.initialize(repeating: 0, count: 2)
        recordAddress = unsafe vm_address_t(UInt(bitPattern: record))
        recordSize = vm_size_t(2 * word)
        task = mach_task_self_
    }

    deinit {
        // SAFETY: the allocations of init; nothing else holds `self` any more.
        unsafe buffer.deallocate()
        unsafe registers.deallocate()
        unsafe record.deallocate()
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

    /// Caller has suspended the thread. No allocation, no lock and no Swift
    /// runtime call in here, in any build (the type comment says why).
    private func walk() -> Int {
        var count = stateCount
        // SAFETY: stateWords points at `registers`, which holds stateCount words of the thread state (init).
        guard unsafe thread_get_state(thread, flavor, stateWords, &count) == KERN_SUCCESS else { return 0 }
        // SAFETY: pcIndex, fpIndex and lrIndex (when >= 0) are word offsets inside the state, under its capacity.
        var fp = unsafe (registers + fpIndex).pointee
        var frames = 0
        store(Self.strip(unsafe (registers + pcIndex).pointee), at: frames)
        frames += 1
        if lrIndex >= 0, unsafe (registers + lrIndex).pointee != 0, frames < maxFrames {
            store(Self.strip(unsafe (registers + lrIndex).pointee), at: frames)
            frames += 1
        }
        while fp != 0, fp & 0x7 == 0, frames < maxFrames {
            var size: vm_size_t = 0
            // SAFETY: vm_read_overwrite copies recordSize bytes (two words) into `record` (two words, init) and fails,
            // without a fault, when `fp` is not readable; it writes the size it copied into `size`.
            guard unsafe vm_read_overwrite(task, fp, recordSize, recordAddress, &size) == KERN_SUCCESS else { break }
            let next = unsafe record.pointee
            let returnAddress = unsafe (record + 1).pointee
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
