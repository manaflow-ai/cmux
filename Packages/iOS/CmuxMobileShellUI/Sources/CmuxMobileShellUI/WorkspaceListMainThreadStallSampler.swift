#if os(iOS) && DEBUG
import CmuxMobileDiagnostics
import Darwin
import Foundation

/// Debug-only record of what the main thread runs when it stalls a scroll.
///
/// The main thread stamps a heartbeat every display frame while a list scroll
/// session is active. A background thread watches that heartbeat; once it is
/// older than ``stallThreshold`` the watcher suspends the main thread, copies
/// its return addresses by walking the frame-pointer chain, and resumes it.
/// Nothing allocates or takes a lock while the main thread is suspended, since
/// it may hold the allocator's lock. When the stall ends, the samples are
/// symbolicated and logged as `workspace-list.stall`.
final class WorkspaceListMainThreadStallSampler: @unchecked Sendable {
    // lint:allow single aligned 64-bit word written by the main thread and read
    // by the watcher; torn reads are impossible on arm64 and a stale read only
    // delays one sample. Debug instrumentation, never compiled into release.
    nonisolated(unsafe) private static var heartbeat: UInt64 = 0
    nonisolated(unsafe) private static var running = false

    private static let stallThreshold: Double = 0.030
    private static let sampleInterval: useconds_t = 4_000
    private static let maxFrames = 48
    private static let maxSamplesPerStall = 64

    private let mainThread: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let frames: UnsafeMutablePointer<UInt>
    private var samples: [[UInt]] = []

    /// Starts watching; call on the main thread when a scroll session begins.
    @MainActor
    static func start() {
        guard !running else { return }
        running = true
        beat()
        let sampler = WorkspaceListMainThreadStallSampler()
        let thread = Thread { sampler.watch() }
        thread.name = "cmux.workspace-list.stall-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops watching after the current stall, if any, is reported.
    @MainActor
    static func stop() {
        running = false
    }

    /// Marks the main thread alive; call once per displayed frame.
    @MainActor
    static func beat() {
        heartbeat = mach_absolute_time()
    }

    @MainActor
    private init() {
        mainThread = pthread_mach_thread_np(pthread_self())
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(pthread_self()))
        frames = .allocate(capacity: Self.maxFrames)
    }

    deinit {
        frames.deallocate()
    }

    private func watch() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        var stallStart: UInt64 = 0
        while Self.running || !samples.isEmpty {
            usleep(Self.sampleInterval)
            let beat = Self.heartbeat
            let age = Double(mach_absolute_time() &- beat) / ticksPerSecond
            if Self.running, age > Self.stallThreshold {
                if stallStart == 0 { stallStart = beat }
                if samples.count < Self.maxSamplesPerStall, let stack = sampleMainThread() {
                    samples.append(stack)
                }
            } else if !samples.isEmpty {
                let milliseconds = Double(Self.heartbeat &- stallStart) / ticksPerSecond * 1000
                report(stallMilliseconds: milliseconds)
                samples.removeAll(keepingCapacity: true)
                stallStart = 0
            }
        }
    }

    /// Copies the main thread's return addresses. Returns `nil` if the thread
    /// state could not be read.
    private func sampleMainThread() -> [UInt]? {
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return nil }
        let status = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        var depth = 0
        if status == KERN_SUCCESS {
            frames[depth] = Self.strip(UInt(state.__pc)); depth += 1
            frames[depth] = Self.strip(UInt(state.__lr)); depth += 1
            var fp = UInt(state.__fp)
            while depth < Self.maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
                let record = UnsafePointer<UInt>(bitPattern: fp)!
                let next = record[0]
                frames[depth] = Self.strip(record[1]); depth += 1
                guard next > fp else { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        guard status == KERN_SUCCESS else { return nil }
        return Array(UnsafeBufferPointer(start: frames, count: depth))
    }

    /// Removes pointer-authentication bits from a code address.
    private static func strip(_ address: UInt) -> UInt {
        address & 0x0000_007F_FFFF_FFFF
    }

    private func report(stallMilliseconds: Double) {
        // Frames seen in the most samples are where the stall spent its time.
        var hits: [UInt: Int] = [:]
        for stack in samples {
            for address in Set(stack) { hits[address, default: 0] += 1 }
        }
        let representative = samples.max { lhs, rhs in
            lhs.reduce(0) { $0 + (hits[$1] ?? 0) } < rhs.reduce(0) { $0 + (hits[$1] ?? 0) }
        } ?? []
        let symbols = representative.prefix(40).map { address -> String in
            "\(Self.symbol(for: address))×\(hits[address] ?? 0)"
        }
        MobileDebugLog.anchormux(
            "workspace-list.stall ms=\(Int(stallMilliseconds)) samples=\(samples.count) stack=\(symbols.joined(separator: " | "))"
        )
    }

    private static func symbol(for address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { String(cString: $0) }
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image):\(name)"
    }
}
#endif
