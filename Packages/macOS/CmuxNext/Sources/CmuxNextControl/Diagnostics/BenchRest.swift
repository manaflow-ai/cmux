#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings

/// How long a bench rests on each step (`debug.hover_sweep` `rest_ms`): the parameter when it is a
/// positive number of milliseconds, else `fallback`. A rest shorter than a dwell the bench means to
/// reach (the strip's hover-load dwell) never reaches it, so the caller's fallback covers that dwell.
public struct BenchRest {
    public init() {}
    public static func milliseconds(_ params: [String: JSONValue], key: String = "rest_ms", fallback: Duration) -> Double {
        if let ms = params[key]?.doubleValue, ms.isFinite, ms > 0 { return ms }
        let parts = fallback.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
#endif
