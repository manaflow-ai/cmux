import CoreFoundation
import Foundation
import os
import CmuxNextCompat

extension MainThreadWatchdog {
    /// A run-loop entry or exit on the main thread (the heartbeat): wakes the watchdog thread when a
    /// nested default-mode run starts or a reported one ends.
    func noteRunLoopEdge(_ activity: CFRunLoopActivity, now: UInt64) {
        if activity == .entry {
            if nested.entered(now: now, inDefaultMode: NestedRunLoopWatch.mainLoopInDefaultMode) { alarm.wake() }
        } else if activity == .exit {
            if nested.exited(now: now) { alarm.wake() }
        }
    }

    /// Reports a nested run of the main run loop parked past the hang threshold with no input
    /// (``NestedRunLoopWatch``), and closes its hang file once it ended. Watchdog thread only.
    func checkNestedRunLoop(sampler: ThreadStackSampler?) {
        switch nested.take(now: uptime(), hangNanos: hangNanos) {
        case .idle:
            return
        case let .ended(id, durationNanos):
            let duration = Duration.nanoseconds(Int64(clamping: durationNanos))
            logger.fault("main thread left a nested run loop after \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms with no input taken")
            episodes?.update(beat: NestedRunLoopWatch.episodeKey(id), duration: duration, ongoing: false)
        case let .report(id, elapsedNanos):
            let duration = Duration.nanoseconds(Int64(clamping: elapsedNanos))
            lastHangUptime.store(uptime(), ordering: .releasing)
            let host = HostLoad.current()
            logger.fault("main thread parked in a nested run loop: \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms and counting with no input taken (Application Not Responding), \(StallVerdict.waiting.rawValue, privacy: .public): host load \(host?.one ?? -1, format: .fixed(precision: 1)) on \(host?.cores ?? 0) cores; its stack is in the hang file")
            // The main thread sleeps in the nested run: the frames under it name the caller.
            let main = sampler?.sample() ?? []
            let others = sampler.map { ThreadStackSampler.sampleOtherThreads(excluding: $0.thread) } ?? []
            episodes?.begin(beat: NestedRunLoopWatch.episodeKey(id), elapsed: duration, main: main, others: others,
                            load: HangLoad(host: host, idleWait: true))
            onHang?(Hang(duration: duration, addresses: main, otherThreads: others))
        }
    }
}
