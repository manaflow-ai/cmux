import Darwin
import Foundation

/// Samples another thread's stack by suspending it and walking its frame
/// pointer chain. Used only from the watchdog thread.
///
/// Between `thread_suspend` and `thread_resume` the code must not allocate
/// or take locks the target might hold (malloc, the Swift runtime): it
/// writes into a preallocated buffer and reads memory with
/// `vm_read_overwrite`, which fails safely on a bad pointer.
final class ThreadStackSampler: @unchecked Sendable {
    let thread: thread_act_t
    let maxFrames: Int
    // Only the watchdog thread touches the buffer.
    private let buffer: UnsafeMutablePointer<UInt>

    init(thread: thread_act_t, maxFrames: Int = 64) {
        self.thread = thread
        self.maxFrames = maxFrames
        buffer = .allocate(capacity: maxFrames)
    }

    deinit {
        buffer.deallocate()
    }

    /// Return addresses, innermost first. Empty when the thread could not be
    /// suspended or its state could not be read.
    func sample() -> [UInt] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let count = walk()
        thread_resume(thread)
        return (0..<count).map { buffer[$0] }
    }

    /// Caller has suspended the thread. No allocation in here.
    private func walk() -> Int {
        var pc: UInt = 0
        var fp: UInt = 0
        var lr: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc)
        fp = UInt(state.__fp)
        lr = UInt(state.__lr)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, x86_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip)
        fp = UInt(state.__rbp)
        #endif
        var frames = 0
        buffer[frames] = Self.strip(pc)
        frames += 1
        if lr != 0, frames < maxFrames {
            buffer[frames] = Self.strip(lr)
            frames += 1
        }
        var pair: (UInt, UInt) = (0, 0)
        while fp != 0, fp & 0x7 == 0, frames < maxFrames {
            var size: vm_size_t = 0
            let read = withUnsafeMutablePointer(to: &pair) { pointer in
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                  vm_address_t(UInt(bitPattern: pointer)), &size)
            }
            guard read == KERN_SUCCESS else { break }
            let (next, returnAddress) = pair
            guard returnAddress != 0 else { break }
            buffer[frames] = Self.strip(returnAddress)
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

    /// Resolves addresses to image, symbol, and offset. Safe off the main
    /// thread; call after `sample()` returned.
    static func symbolicate(_ addresses: [UInt]) -> [HangFrame] {
        addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
                return HangFrame(address: address, image: nil, symbol: nil, offset: 0)
            }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent }
            let symbol = info.dli_sname.map { demangle(String(cString: $0)) }
            let base = info.dli_saddr.map { UInt(bitPattern: $0) } ?? address
            return HangFrame(address: address, image: image, symbol: symbol, offset: address &- base)
        }
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: Demangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let swiftDemangle else { return name }
        return name.withCString { raw in
            guard let result = swiftDemangle(raw, strlen(raw), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }
}
