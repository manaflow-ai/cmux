/// How a coordinator-built script runs in the target browser surface,
/// mirroring the two legacy JavaScript primitives.
public enum ControlBrowserScriptMode: Sendable, Equatable {
    /// The legacy `v2RunBrowserJavaScript` path: frame-selector aware, result
    /// envelope (undefined detection), page-world with isolated-world retry.
    ///
    /// - Parameter useEval: The legacy `useEval` flag (`true` wraps the script
    ///   in `eval(...)`; `false` embeds it as an expression).
    case frameAware(useEval: Bool)
    /// The legacy direct `v2RunJavaScript(…, contentWorld: .page)` path used by
    /// the console/error log readers, optionally bootstrapping the telemetry
    /// hooks first (the legacy `v2BrowserEnsureTelemetryHooks`).
    case pageWorld(installTelemetryHooks: Bool)
}
