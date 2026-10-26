#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Darwin
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The wire measurements `debug.chromium_host.measure` asks the running host for.
extension ChromiumHostSession {
    /// `count` round trips cmux -> host UI thread -> cmux, in microseconds.
    public func ping(count: Int) async -> [Double] {
        var samples: [Double] = []
        for _ in 0..<count {
            seq &+= 1
            let id = seq
            let sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            var frame = ChromiumHostFrame(.ping, t0: sent)
            frame.seq = id
            let pong: ChromiumHostFrame? = await withTaskCancellationHandler {
                // A waiter dropped unanswered (abandoned) is a missing pong: nil.
                try? await withOnceContinuation { (continuation: OnceContinuation<ChromiumHostFrame?, OnceContinuationError>) in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    pongs[id] = continuation
                    if !send(frame) { pongs.removeValue(forKey: id)?.resume(returning: nil) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.pongs.removeValue(forKey: id)?.resume(returning: nil) }
            }
            guard pong != nil, !Task.isCancelled else { break }
            samples.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - sent) / 1_000)
        }
        return samples
    }

    /// The host's input timing: from each event's time in cmux to the host's
    /// `Send*Event` on its UI thread, in microseconds, and how many input frames
    /// the host folded into a waiting one (`coalesced`: pointer moves, wheel deltas), and how often the host
    /// became active or one of its windows key (`activations`, `key_windows`; each undone at once, both 0 normally).
    public func hostInputStats() async -> [String: Int]? {
        seq &+= 1
        let id = seq
        let reply: ChromiumHostFrame? = await withTaskCancellationHandler {
            try? await withOnceContinuation { (continuation: OnceContinuation<ChromiumHostFrame?, OnceContinuationError>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                statsWaiters[id] = continuation
                var frame = ChromiumHostFrame(.stats)
                frame.seq = id
                if !send(frame) { resumeStatsWaiter(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeStatsWaiter(id) }
        }
        guard let reply else { return nil }
        let v = reply.v
        let stats: [String: Int] = [
            "events": Int(v[0]), "p50_us": Int(v[1]), "p95_us": Int(v[2]),
            "p99_us": Int(v[3]), "max_us": Int(v[4]), "refused_frames": Int(v[5]),
            "coalesced": Int(clamping: reply.t1),
            // The host shares cmux's bundle id: it must never become active nor own the key window.
            "activations": Int(reply.t0 >> 32), "key_windows": Int(reply.t0 & 0xffff_ffff),
        ]
        return stats
    }

    private func resumeStatsWaiter(_ id: UInt32) {
        statsWaiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}
#endif
