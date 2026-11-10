#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
import QuartzCore

/// The answers of `debug.home.drive` (CmuxNextApp's DebugHomeNativeFixture) that read this view only.
extension HomeNativeTranscriptView {
    /// `resize {trims}`: width changes in one main-thread turn (one display frame), with the pass
    /// counters and rows after each.
    public func debugResize(trims: [Double]) -> JSONValue {
        func rowsJSON() -> JSONValue {
            .array(debugRowFrames().map { r in
                .object(["kind": .string(r.kind), "key": .string(r.key), "outgoing": .bool(r.outgoing),
                         "x": .number(Double(r.balloon.minX)), "maxX": .number(Double(r.balloon.maxX)),
                         "y": .number(Double(r.balloon.minY))])
            })
        }
        var steps: [JSONValue] = []
        for trim in trims {
            // The step's main-thread time (its width pass with the layout it causes), to tell a deferral the
            // frame budget asks for (a pass of 2 ms or more, e.g. a Debug build) from one it does not.
            let t0 = CACurrentMediaTime()
            debugTrimWidth(CGFloat(trim))
            let ms = (CACurrentMediaTime() - t0) * 1000
            let c = debugWidthPasses
            steps.append(.object(["trim": .number(trim), "passes": .number(Double(c.passes)), "deferred": .number(Double(c.deferred)),
                                  "ms": .number(ms), "rows": rowsJSON()]))
        }
        let c0 = debugWidthPasses
        return .object(["ok": .bool(!trims.isEmpty), "steps": .array(steps), "budgetMs": .number(debugWidthPassBudget * 1000),
                        "passes": .number(Double(c0.passes)), "deferred": .number(Double(c0.deferred))])
    }

    /// Tree threads: `ok`, the open thread (transcript id), the drill path and shown message (owner ids).
    public func debugTreeReply(ok: Bool) -> JSONValue {
        let s: (String?) -> JSONValue = { $0.map { .string($0) } ?? .null }
        return .object(["ok": .bool(ok), "open_thread": s(openThreadRoot), "thread_path": .array(debugOpenThreadPath.map(s)), "thread_message": s(openThreadMessage)])
    }
}
#endif
