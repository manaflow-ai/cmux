public import Foundation

/// (C) ExternalHover diagnostics — the host-side half of design
/// v4 §6.2's "gate is evaluated exactly once" contract. Ghostty (Zig)
/// reads the SAME env var independently, memoized on its own side
/// (`externalHoverDiagnosticsEnabled()` in `renderer/link.zig`) — the two
/// sides never share state, so both must agree only by construction (the
/// same env var, the same `"1"` value), not by any cross-process
/// coordination.
///
/// `isEnabled` is a plain immutable instance property, not
/// `ProcessInfo.processInfo.environment` re-read on every mouse-moved. The
/// app constructs one gate per native surface and injects it into the
/// surface's coordinators, so the hot path is one plain `Bool` compare.
///
/// Review non-blocking N3 — the explicit Release-build contract: this
/// gate is readable (and, if the env var is set, `true`) in EVERY build
/// configuration, Release included. Setting the env var on a Release
/// build genuinely activates the ring/demand/drain machinery (every call
/// site that checks `isEnabled` or an injected `diagnosticsEnabled`
/// closure does so outside `#if DEBUG`). The human-readable log LINES
/// this gate unlocks (`logDebugEvent`/`cmuxDebugLog` calls) are, per the
/// project's own established convention, wrapped in `#if DEBUG` and so
/// disappear in Release regardless of this gate — Release-mode
/// diagnostics are therefore only useful today via a debugger inspecting
/// live ring/tracker state directly, not via the log. This is the
/// intentional decision (not an oversight): the gate's SCOPE (which
/// builds can turn the mechanism on at all) and DEBUG's scope (which
/// builds can see the resulting text) are deliberately independent
/// knobs, matching every other `#if DEBUG`-gated `logDebugEvent` call in
/// this codebase.
public struct ExternalHoverDiagnosticsGate: Sendable {
    /// Whether diagnostics are enabled for the process environment captured at initialization.
    public let isEnabled: Bool

    /// Captures the diagnostics switch once so callers can inject a stable gate.
    ///
    /// - Parameter environment: The environment to inspect. Production callers
    ///   use the default process environment; tests can provide a deterministic
    ///   dictionary without mutating process-global state.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isEnabled = environment["CMUX_EXTERNAL_HOVER_DIAGNOSTICS"] == "1"
    }
}
