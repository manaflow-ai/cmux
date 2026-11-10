import Dispatch
import Foundation
import os
import CmuxNextCompat
import CmuxNextSettings

/// The starvation probe's dispatch timer (cancel is thread-safe).
final class ProbeTimer: @unchecked Sendable {
    let source: DispatchSourceTimer
    init(_ source: DispatchSourceTimer) { self.source = source }
}

extension MainThreadWatchdog {
    /// Starts the starvation probe (``Configuration/starvationProbeInterval``): a utility-queue
    /// timer that reads the host load and, only while it is above the core count, sends the
    /// main queue one block and times its answer. The heartbeat reads a main thread asleep in
    /// its event wait as idle, so an idle main thread the Mac gives no CPU (the Dock's
    /// "Application Not Responding" with no hang file, cmuxterm-hq#8504) is seen only this way.
    func startStarvationProbe() {
        guard let interval = configuration.starvationProbeInterval else { return }
        let nanos = Int(clamping: Self.nanos(interval))
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + .nanoseconds(nanos), repeating: .nanoseconds(nanos), leeway: .nanoseconds(nanos / 5))
        source.setEventHandler { [weak self] in self?.probeTick() }
        probeTimer.withLock { $0 = ProbeTimer(source) }
        source.resume()
    }

    func stopStarvationProbe() {
        probeTimer.withLock { timer in timer?.source.cancel(); timer = nil }
    }

    /// One probe check (utility queue): nothing reaches the main thread unless the host is overloaded.
    private func probeTick() {
        guard running.load(ordering: .relaxed), let host = HostLoad.current(), host.isOverloaded,
              probeOutstanding.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        let sentAt = uptime()
        let cpuAt = busy.mainThreadCPUNanos()
        DispatchQueue.main.async { [self] in
            let answeredAt = uptime()
            let cpuNow = busy.mainThreadCPUNanos()
            probeOutstanding.store(false, ordering: .releasing)
            let cpu = cpuAt.flatMap { start in cpuNow.map { $0 > start ? $0 - start : 0 } }
            noteProbeAnswered(sentAt: sentAt, delayNanos: answeredAt > sentAt ? answeredAt - sentAt : 0, cpuNanos: cpu,
                              host: HostLoad.current() ?? host)
        }
    }

    /// The main queue answered a probe sent at `sentAt` after `delayNanos`, with the main thread
    /// using `cpuNanos` meanwhile on a host at `host` load. A delay past the hang threshold (2 s)
    /// with a `starved` verdict is recorded: a stall record, a fault line and a hang file. A
    /// `blocked` delay is the stall path's to record, and a hang reported meanwhile already has
    /// its record. Returns the record, if any. Main thread (tests call it directly).
    @discardableResult
    func noteProbeAnswered(sentAt: UInt64, delayNanos: UInt64, cpuNanos: UInt64?, host: HostLoad?) -> HangRecord? {
        guard delayNanos >= hangNanos else { return nil }
        let duration = Duration.nanoseconds(Int64(clamping: delayNanos))
        let cpu = cpuNanos.map { Duration.nanoseconds(Int64(clamping: $0)) }
        guard StallVerdict.classify(wall: duration, mainThreadCPU: cpu, host: host) == .starved,
              lastHangUptime.load(ordering: .acquiring) < sentAt else { return nil }
        var details: [String: JSONValue] = ["verdict": .string(StallVerdict.starved.rawValue), "source": .string("starvation_probe")]
        if let host {
            details["host_load_1m"] = .number(host.one)
            details["host_cores"] = .number(Double(host.cores))
        }
        let record = log.append(startUptimeNanos: sentAt, duration: duration, cpu: cpu ?? .zero, addresses: [], details: details)
        logger.fault("main thread starved: the main queue answered after \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms with \(cpu?.fractionalMilliseconds ?? -1, format: .fixed(precision: 0)) ms of main-thread cpu, host load \(host?.one ?? -1, format: .fixed(precision: 1)) on \(host?.cores ?? 0) cores (the Mac, not our code; hang \(record.sequence))")
        if let recorder = episodes {
            // Below the nested runs' keys (which count down from the top), far above heartbeat beats.
            let key = UInt64.max / 2 - probeSequence.add(1, ordering: .relaxed).newValue
            let load = HangLoad(mainThreadCPU: cpu, host: host)
            recorder.begin(beat: key, elapsed: duration, main: [], others: [], load: load)
            recorder.update(beat: key, duration: duration, ongoing: false, load: load)
        }
        return record
    }
}
