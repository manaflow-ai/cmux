import Dispatch
import Foundation
import os
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups

extension MainThreadWatchdog {
    /// Starts the starvation probe (``Configuration/starvationProbeInterval``): a utility-queue
    /// check, once per interval while the watchdog runs, that reads the host load and, only while it is above the core count, sends the
    /// main queue one block and times its answer. The heartbeat reads a main thread asleep in
    /// its event wait as idle, so an idle main thread the Mac gives no CPU (the Dock's
    /// "Application Not Responding" with no hang file, cmuxterm-hq#8504) is seen only this way.
    func startStarvationProbe() {
        guard let interval = configuration.starvationProbeInterval else { return }
        scheduleProbe(after: interval)
    }

    /// One-shot deadline, re-armed after each check until stop() (``DemandTimer``: the wakeup
    /// ledger counts it under its owner).
    private func scheduleProbe(after interval: Duration) {
        probeTimer.schedule(after: interval) { [weak self] in
            guard let self, running.load(ordering: .acquiring) else { return }
            probeTick()
            scheduleProbe(after: interval)
        }
    }

    /// One probe check (utility queue): nothing reaches the main thread unless the host is overloaded.
    private func probeTick() {
        guard let host = HostLoad.current(), host.isOverloaded,
              probeOutstanding.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
        else { return }
        let sentAt = uptime()
        let cpuAt = busy.mainThreadCPUNanos()
        let memoryAt = HostMemory.current()
        // main-async-allow: the probe measures the main dispatch queue's own answer delay, so it must be a raw GCD hop (no scheduler between).
        DispatchQueue.main.async { [self] in
            let answeredAt = uptime()
            let delay = answeredAt > sentAt ? answeredAt - sentAt : 0
            let cpuNow = busy.mainThreadCPUNanos()
            let cpu = cpuAt.flatMap { start in cpuNow.map { $0 > start ? $0 - start : 0 } }
            noteProbeAnswered(sentAt: sentAt, delayNanos: delay, cpuNanos: cpu, memoryAt: memoryAt,
                              host: { HostLoad.peak(host, HostLoad.current()) })
        }
    }

    /// The main queue answered a probe sent at `sentAt` after `delayNanos`, with the main thread
    /// using `cpuNanos` meanwhile on a host at `host` load (`memoryAt`: the host's memory when it
    /// was sent, the base of the hang file's memory line). A delay past the hang threshold (2 s)
    /// with a `starved` verdict is recorded: a stall record, a fault line and a hang file. A
    /// `blocked` delay is the stall path's to record, and a hang reported meanwhile already has
    /// its record. Check for overlap at answer time so a later hang cannot suppress this one.
    func noteProbeAnswered(sentAt: UInt64, delayNanos: UInt64, cpuNanos: UInt64?, memoryAt: HostMemory? = nil,
                           observedAt: Date = Date(), host: @escaping @Sendable () -> HostLoad?) {
        guard delayNanos >= hangNanos, lastHangUptime.load(ordering: .acquiring) < sentAt else {
            probeOutstanding.store(false, ordering: .releasing)
            return
        }
        probeReportQueue.async { [self] in
            defer { probeOutstanding.store(false, ordering: .releasing) }
            recordStarvation(sentAt: sentAt, delayNanos: delayNanos, cpuNanos: cpuNanos, memoryAt: memoryAt,
                             observedAt: observedAt, host: host())
        }
    }

    private func recordStarvation(sentAt: UInt64, delayNanos: UInt64, cpuNanos: UInt64?, memoryAt: HostMemory?,
                                  observedAt: Date, host: HostLoad?) {
        let duration = Duration.nanoseconds(Int64(clamping: delayNanos))
        let cpu = cpuNanos.map { Duration.nanoseconds(Int64(clamping: $0)) }
        guard StallVerdict.classify(wall: duration, mainThreadCPU: cpu, host: host) == .starved else { return }
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
            let memory = memoryAt.flatMap { start in HostMemory.current().map { HostMemoryDelta(from: start, to: $0) } }
            let load = HangLoad(mainThreadCPU: cpu, host: host, memory: memory)
            recorder.begin(beat: key, elapsed: duration, main: [], others: [], load: load, observedAt: observedAt)
            recorder.update(beat: key, duration: duration, ongoing: false, load: load)
        }
    }
}
