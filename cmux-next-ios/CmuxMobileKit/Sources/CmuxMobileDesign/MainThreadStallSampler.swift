// DEBUG and Demo builds only, on with the frame log (`FrameLogSwitch`).
#if os(iOS) && DEBUG
import Darwin
import Foundation
import OSLog
import QuartzCore

/// What the main thread was doing during a long frame (G-04): while a `FrameIntervalLog` window is
/// open, a background thread samples the main thread every 2 ms (its run state, and its stack by its
/// frame pointers), and the window's end names the symbols under its frames longer than 50 ms. A
/// frame whose main thread used little CPU (`mainThreadCPUPerFrameMs`) was waiting: these samples say
/// on what. Samples go into a buffer made before sampling starts: nothing allocates while the main
/// thread is suspended (it may hold the allocator's lock).
final class MainThreadStallSampler: @unchecked Sendable {
    // concurrency-allow: written on the sampler thread only while `running`; read on the main thread after `stop` joins it.
    private static let depth = 48
    private static let capacity = 6000
    private let mainPort: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let times: UnsafeMutablePointer<Double>
    private let states: UnsafeMutablePointer<Int32>
    private let frames: UnsafeMutablePointer<UInt>
    private var count = 0
    private let running = ManagedAtomicFlag()
    private let done = DispatchSemaphore(value: 0)

    /// Made on the main thread.
    init() {
        mainPort = mach_thread_self()
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(thread))
        times = .allocate(capacity: Self.capacity)
        states = .allocate(capacity: Self.capacity)
        frames = .allocate(capacity: Self.capacity * Self.depth)
        frames.initialize(repeating: 0, count: Self.capacity * Self.depth)
    }

    deinit {
        mach_port_deallocate(mach_task_self_, mainPort)
        times.deallocate()
        states.deallocate()
        frames.deallocate()
    }

    func start() {
        running.set(true)
        let thread = Thread { [self] in sample() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        guard running.get() else { return }
        running.set(false)
        done.wait()
    }

    private func sample() {
        while running.get(), count < Self.capacity {
            let index = count
            times[index] = CACurrentMediaTime()
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let infoResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(mainPort, thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            states[index] = infoResult == KERN_SUCCESS ? info.run_state : -1
            let row = frames + index * Self.depth
            row[0] = 0
            #if arch(arm64)
            if thread_suspend(mainPort) == KERN_SUCCESS {
                var state = arm_thread_state64_t()
                var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
                let result = withUnsafeMutablePointer(to: &state) {
                    $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                        thread_get_state(mainPort, ARM_THREAD_STATE64, $0, &stateCount)
                    }
                }
                if result == KERN_SUCCESS {
                    row[0] = UInt(state.__pc)
                    row[1] = UInt(state.__lr)
                    var fp = UInt(state.__fp)
                    var n = 2
                    while n < Self.depth, fp >= stackLow, fp + 16 <= stackHigh, fp & 7 == 0 {
                        let pair = UnsafePointer<UInt>(bitPattern: fp)!
                        let next = pair[0]
                        row[n] = pair[1]
                        n += 1
                        guard next > fp else { break }
                        fp = next
                    }
                    if n < Self.depth { row[n] = 0 }
                }
                thread_resume(mainPort)
            }
            #endif
            count = index + 1
            usleep(2000)
        }
        done.signal()
    }

    /// Log lines naming what the main thread did in `ranges` (media times): the share of samples
    /// it was running, and the symbols most often on its stack (inclusive) and on top (self).
    func report(label: String, ranges: [(CFTimeInterval, CFTimeInterval)], log: Logger) {
        guard !ranges.isEmpty else { return }
        var inclusive: [String: Int] = [:]
        var leaf: [String: Int] = [:]
        var names: [UInt: String] = [:]
        var samples = 0, runningSamples = 0
        func name(_ address: UInt) -> String {
            if let known = names[address] { return known }
            var info = Dl_info()
            var text = String(format: "0x%lx", address)
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                text = "\(image)`\(symbol.prefix(160))"
            }
            names[address] = text
            return text
        }
        for index in 0..<count {
            let time = times[index]
            guard ranges.contains(where: { time >= $0.0 && time <= $0.1 }) else { continue }
            samples += 1
            if states[index] == TH_STATE_RUNNING { runningSamples += 1 }
            let row = frames + index * Self.depth
            var seen = Set<String>()
            for n in 0..<Self.depth {
                let address = row[n]
                guard address != 0 else { break }
                let symbol = name(address)
                if n == 0 { leaf[symbol, default: 0] += 1 }
                if seen.insert(symbol).inserted { inclusive[symbol, default: 0] += 1 }
            }
        }
        log.notice("FRAMELOG list-stress stall \(label, privacy: .public) frames=\(ranges.count) samples=\(samples) running=\(runningSamples)")
        for (symbol, n) in leaf.sorted(by: { $0.value > $1.value }).prefix(20) {
            log.notice("FRAMELOG list-stress stall-self \(label, privacy: .public) \(n) \(symbol, privacy: .public)")
        }
        for (symbol, n) in inclusive.sorted(by: { $0.value > $1.value }).prefix(60) {
            log.notice("FRAMELOG list-stress stall-incl \(label, privacy: .public) \(n) \(symbol, privacy: .public)")
        }
    }
}

/// A flag two threads read and write.
private final class ManagedAtomicFlag: @unchecked Sendable {
    // concurrency-allow: every access holds `lock`.
    private var value = false
    private let lock = NSLock()
    func get() -> Bool { lock.withLock { value } }
    func set(_ new: Bool) { lock.withLock { value = new } }
}
#endif
