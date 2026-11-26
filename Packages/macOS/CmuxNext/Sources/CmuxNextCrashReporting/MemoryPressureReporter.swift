public import CmuxNextCompat
public import CmuxNextWakeups
public import Darwin
public import Foundation
public import Sentry

/// A process that contributed to the app's physical footprint sample.
public nonisolated struct MemoryPressureOwner: Sendable, Equatable {
    public let name: String
    public let footprintMegabytes: Int

    public init(name: String, footprintMegabytes: Int) {
        self.name = name
        self.footprintMegabytes = footprintMegabytes
    }

    var eventValue: String { "\(name):\(footprintMegabytes)" }
}

/// The bounded, privacy-safe payload sent for a memory incident.
public nonisolated struct MemoryPressureReport: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case warning
        case critical
        case highFootprint = "high_footprint"
        case previousOOM = "previous_oom"
    }

    public let kind: Kind
    public let footprintMegabytes: Int
    public let topOwners: [MemoryPressureOwner]
    public let uptimeNanos: UInt64

    public init(kind: Kind, footprintMegabytes: Int, topOwners: [MemoryPressureOwner], uptimeNanos: UInt64) {
        self.kind = kind
        self.footprintMegabytes = max(0, footprintMegabytes)
        self.topOwners = Array(topOwners.prefix(8))
        self.uptimeNanos = uptimeNanos
    }

    /// The event at the Sentry capture boundary. The reporter's normal
    /// `beforeSend` hook adds the app, release and install labels.
    public func event() -> Event {
        let event = Event(level: .error)
        let message = "cmux memory \(kind.rawValue)"
        event.message = SentryMessage(formatted: message)
        let exception = Exception(value: message, type: "MemoryPressure")
        let mechanism = Mechanism(type: "cmux_memory_pressure")
        mechanism.handled = true
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.fingerprint = ["memory-pressure", kind.rawValue]
        event.tags = ["memory_event": kind.rawValue]
        event.extra = [
            "footprint_mb": footprintMegabytes,
            "top_owners": topOwners.map(\.eventValue),
            "uptime_nanos": uptimeNanos,
        ]
        return event
    }
}

/// A process-tree footprint sample. It contains no paths or command lines.
public nonisolated struct MemoryPressureSnapshot: Sendable, Equatable {
    public let footprintMegabytes: Int
    public let topOwners: [MemoryPressureOwner]
    public let uptimeNanos: UInt64

    public init(footprintMegabytes: Int, topOwners: [MemoryPressureOwner], uptimeNanos: UInt64) {
        self.footprintMegabytes = max(0, footprintMegabytes)
        self.topOwners = Array(topOwners.prefix(8))
        self.uptimeNanos = uptimeNanos
    }

    /// Samples this app and its descendants off the main thread.
    public static func current(maxOwners: Int = 5) -> Self {
        let root = getpid()
        var pending = [root]
        var pids: Set<pid_t> = [root]
        while let pid = pending.popLast() {
            for child in ProcessUsage.children(of: pid) where pids.insert(child).inserted {
                pending.append(child)
            }
        }

        let samples = pids.compactMap(ProcessUsage.sample)
        let app = samples.first { $0.pid == root }
        let owners = samples.sorted { lhs, rhs in
            if lhs.physFootprint != rhs.physFootprint { return lhs.physFootprint > rhs.physFootprint }
            return lhs.pid < rhs.pid
        }.prefix(max(0, maxOwners)).map {
            MemoryPressureOwner(name: $0.name.isEmpty ? "unknown" : $0.name,
                                 footprintMegabytes: Int($0.physFootprint / 1_048_576))
        }
        let footprint = app.map { Int($0.physFootprint / 1_048_576) } ?? 0
        let uptime = app?.uptimeNanos ?? clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return Self(footprintMegabytes: footprint, topOwners: Array(owners), uptimeNanos: uptime)
    }
}

/// Token-bucket limiter for memory reports. Memory pressure can deliver a
/// burst of changes while the system is reclaiming pages, so the capture path
/// must stay bounded even when the signal keeps oscillating.
public nonisolated struct MemoryPressureRateLimiter: Sendable, Equatable {
    public let capacity: Int
    public let refillNanos: UInt64
    private var tokens: Int
    private var lastRefillNanos: UInt64?

    public init(capacity: Int = 4, refillNanos: UInt64 = 900_000_000_000) {
        self.capacity = max(1, capacity)
        self.refillNanos = max(1, refillNanos)
        tokens = max(1, capacity)
    }

    public mutating func admit(nowNanos: UInt64) -> Bool {
        if let lastRefillNanos {
            if nowNanos > lastRefillNanos {
                let earned = (nowNanos - lastRefillNanos) / refillNanos
                if earned > 0 {
                    tokens = min(capacity, tokens + Int(clamping: earned))
                    self.lastRefillNanos = lastRefillNanos &+ earned &* refillNanos
                }
            }
        } else {
            lastRefillNanos = nowNanos
        }
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }
}

/// Converts pressure and footprint samples into rate-limited Sentry reports.
public final class MemoryPressureReporter: Sendable {
    public typealias Sink = @Sendable (MemoryPressureReport) -> Void

    public static let defaultHighFootprintMegabytes = 4 * 1024
    public static let highFootprintEnvironmentKey = "CMUX_NEXT_MEMORY_FOOTPRINT_MB"

    private let isEnabled: @Sendable () -> Bool
    private let sink: Sink
    private let limiter: Mutex<MemoryPressureRateLimiter>
    private let highFootprintMegabytes: Int
    private let uptime: @Sendable () -> UInt64

    public convenience init(reporter: CrashReporter,
                             limiter: MemoryPressureRateLimiter = MemoryPressureRateLimiter(),
                             highFootprintMegabytes: Int = MemoryPressureReporter.highFootprintThreshold()) {
        self.init(limiter: limiter, isEnabled: { reporter.isStarted }, highFootprintMegabytes: highFootprintMegabytes,
                  sink: { reporter.reportMemoryPressure($0) })
    }

    public init(limiter: MemoryPressureRateLimiter = MemoryPressureRateLimiter(),
                isEnabled: @escaping @Sendable () -> Bool,
                highFootprintMegabytes: Int = MemoryPressureReporter.defaultHighFootprintMegabytes,
                sink: @escaping Sink,
                uptime: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.limiter = Mutex(limiter)
        self.isEnabled = isEnabled
        self.highFootprintMegabytes = max(1, highFootprintMegabytes)
        self.sink = sink
        self.uptime = uptime
    }

    /// Reports a kernel pressure transition with its contemporaneous sample.
    @discardableResult
    public func note(level: MemoryPressureLevel, snapshot: MemoryPressureSnapshot) -> Bool {
        let kind: MemoryPressureReport.Kind = switch level {
        case .normal: .highFootprint
        case .warning: .warning
        case .critical: .critical
        }
        if level == .normal, snapshot.footprintMegabytes < highFootprintMegabytes { return false }
        return send(MemoryPressureReport(kind: kind, footprintMegabytes: snapshot.footprintMegabytes,
                                         topOwners: snapshot.topOwners, uptimeNanos: snapshot.uptimeNanos))
    }

    /// Reports a high-footprint sample even when the kernel has not changed
    /// pressure level.
    @discardableResult
    public func noteFootprint(_ snapshot: MemoryPressureSnapshot) -> Bool {
        guard snapshot.footprintMegabytes >= highFootprintMegabytes else { return false }
        return send(MemoryPressureReport(kind: .highFootprint, footprintMegabytes: snapshot.footprintMegabytes,
                                         topOwners: snapshot.topOwners, uptimeNanos: snapshot.uptimeNanos))
    }

    /// Reports a signal-less, high-footprint previous run discovered at launch.
    @discardableResult
    public func notePreviousOOM(_ snapshot: MemoryPressureSnapshot) -> Bool {
        send(MemoryPressureReport(kind: .previousOOM, footprintMegabytes: snapshot.footprintMegabytes,
                                  topOwners: snapshot.topOwners, uptimeNanos: snapshot.uptimeNanos))
    }

    private func send(_ report: MemoryPressureReport) -> Bool {
        guard isEnabled() else { return false }
        let now = uptime()
        guard limiter.withLock({ $0.admit(nowNanos: now) }) else { return false }
        sink(report)
        return true
    }

    public static func highFootprintThreshold(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        max(256, environment[highFootprintEnvironmentKey].flatMap(Int.init) ?? defaultHighFootprintMegabytes)
    }
}

public extension CrashReporter {
    /// Captures one bounded memory-pressure event at Sentry's event boundary.
    nonisolated func reportMemoryPressure(_ report: MemoryPressureReport) {
        guard isStarted else { return }
        SentrySDK.capture(event: report.event())
    }
}
