import Darwin
import Foundation

/// Who held up a main-thread stall: our code, the Mac, or nobody (an idle wait).
///
/// The Dock flags an app whose main thread misses WindowServer's ping deadline. That happens
/// when our code blocks the main thread, and also when an overloaded Mac gives a runnable but
/// idle main thread no CPU (cosmic-gray at load 205 on 2026-11-09: the Dock flagged a NIGHTLY
/// whose main thread sampled 97% idle, cmuxterm-hq#8504). Every stall record says which.
public enum StallVerdict: String, Sendable, Equatable {
    /// Our code held the main thread: it ran (CPU for much of the stall) or waited in a syscall
    /// or on a lock on a Mac with CPU to spare.
    case blocked
    /// The Mac starved the main thread: almost no main-thread CPU over the stall while the host
    /// load was above its core count.
    case starved
    /// An idle wait: the main thread sat in a nested run loop taking no input.
    case waiting

    /// Main-thread CPU under this share of the stall is "near zero".
    static let starvedCPUShare = 0.1

    /// The verdict for a stall `wall` long in which the main thread used `mainThreadCPU`
    /// (nil when unknown), on a host at `host` load (nil when unknown). `idleWait`: the main
    /// thread was parked in a nested run loop.
    public static func classify(wall: Duration, mainThreadCPU: Duration?, host: HostLoad?, idleWait: Bool = false) -> StallVerdict {
        if idleWait { return .waiting }
        guard let mainThreadCPU, let host, wall > .zero else { return .blocked }
        return mainThreadCPU / wall < starvedCPUShare && host.isOverloaded ? .starved : .blocked
    }

    /// The hang file's explanation.
    var explanation: String {
        switch self {
        case .blocked: "our code held the main thread (its own work, or a wait in a syscall or on a lock)"
        case .starved: "the Mac starved the main thread of CPU (little main-thread CPU, host load above its core count)"
        case .waiting: "an idle wait (a nested run loop taking no input)"
        }
    }
}

/// The host's load averages (`getloadavg`) and its active core count.
public struct HostLoad: Sendable, Equatable {
    public var one: Double
    public var five: Double
    public var fifteen: Double
    public var cores: Int

    public init(one: Double, five: Double, fifteen: Double, cores: Int) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
        self.cores = cores
    }

    /// More runnable threads than cores over the last minute.
    public var isOverloaded: Bool { one > Double(max(cores, 1)) }

    /// The load now; nil when `getloadavg` fails. One sysctl, no allocation (safe on the main
    /// thread at a stall's end).
    public static func current() -> HostLoad? {
        var loads: (Double, Double, Double) = (0, 0, 0)
        let count = withUnsafeMutableBytes(of: &loads) { getloadavg($0.baseAddress?.assumingMemoryBound(to: Double.self), 3) }
        guard count == 3 else { return nil }
        return HostLoad(one: loads.0, five: loads.1, fifteen: loads.2, cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// `host load: 205.1 / 172.0 / 144.3 on 10 cores (overloaded)`.
    var line: String {
        String(format: "host load: %.1f / %.1f / %.1f on %d cores", one, five, fifteen, cores) + (isOverloaded ? " (overloaded)" : "")
    }
}
