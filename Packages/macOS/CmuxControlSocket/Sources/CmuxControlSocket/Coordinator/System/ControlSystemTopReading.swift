internal import Foundation

/// The live-app seam for the worker-lane `system.top` / `system.memory`
/// commands, read by ``ControlSystemTopWorker``.
///
/// The base-payload tree walk (`AppDelegate` → each window's `TabManager` →
/// `Workspace` panes/surfaces/tags), the per-window/workspace/pane/surface/tag
/// process attribution against the live `CmuxTopProcessSnapshot`, and the
/// `[String: Any]` annotation pipeline (the legacy `v2AnnotateTop*` helpers) all
/// live app-side because they reach `AppDelegate` and an app-target process
/// snapshot, which this control package must not import.
/// ``ControlSystemTopReading`` inverts that: the package owns the protocol and
/// the command dispatch; the app's conformer performs the reach and returns the
/// already-shaped ``ControlCallResult``, byte-faithful to the legacy
/// `v2SystemTop` / `v2SystemMemory` bodies.
///
/// ## Isolation
///
/// `Sendable`, NOT `@MainActor`: `system.top` / `system.memory` run on the
/// nonisolated socket-worker lane. The legacy bodies were `nonisolated` and
/// sampled the process snapshot on the worker thread, hopping to the main actor
/// only inside the `v2MainSync` block that built the base payload.
/// ``resolveTop(params:)`` / ``resolveMemory(params:)`` preserve that: each is a
/// synchronous, blocking call made from the worker thread, with the main-actor
/// hop kept inside the conformer exactly as before.
public protocol ControlSystemTopReading: Sendable {
    /// Resolves a `system.top` request against the live window graph and the
    /// process snapshot, returning the already-shaped wire result.
    ///
    /// Runs synchronously on the calling socket-worker thread (the snapshot
    /// sampling and annotation block there, matching the legacy `v2SystemTop`
    /// body).
    ///
    /// - Parameter params: The raw `system.top` params.
    /// - Returns: The already-shaped command result.
    func resolveTop(params: [String: JSONValue]) -> ControlCallResult

    /// Resolves a `system.memory` request against the live window graph and the
    /// cached process snapshot, returning the already-shaped wire result.
    ///
    /// Runs synchronously on the calling socket-worker thread (matching the
    /// legacy `v2SystemMemory` body).
    ///
    /// - Parameter params: The raw `system.memory` params.
    /// - Returns: The already-shaped command result.
    func resolveMemory(params: [String: JSONValue]) -> ControlCallResult
}
