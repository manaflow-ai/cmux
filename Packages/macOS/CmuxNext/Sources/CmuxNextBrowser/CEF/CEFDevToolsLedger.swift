import CmuxNextWakeups

/// What the wake ledger says about the DevTools calls the app sends (bench and Debug builds, `sendDevTools`): at idle
/// 0.38 results/s came back to the main thread for calls nothing named (cmux20-bench, 2026-11-25, step 7a792760).
nonisolated enum CEFDevToolsLedger {
    /// `devTools call METHOD`, and for `Runtime.evaluate` the name its expression starts with.
    static func reason(method: String, encodedParams: String) -> String {
        let base = "devTools call " + method
        guard method == "Runtime.evaluate", let start = encodedParams.range(of: #""expression":""#)?.upperBound else { return base }
        let name = encodedParams[start...].prefix(80).prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" }
        return name.isEmpty ? base : base + " " + name
    }
}
