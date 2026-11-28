#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextControl

extension NativeTranscriptControl {
    /// `debug.native_transcript {action, ...}` (DEBUG and bench builds; ``handle(_:)`` has the actions), for
    /// `scripts/ci/frame-pacing/transcript_fling.py`. A `fling` with `wait` answers after up to 50 s.
    public func debugMethod() -> ControlMethod {
        ControlMethod.async("debug.native_transcript") { [weak self] call in
            await self?.handle(call.params) ?? .null
        }.withDeadline(.fixed(.seconds(60)))
    }
}
#endif
