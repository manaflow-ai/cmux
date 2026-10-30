/// The sections of `debug.input`'s read, in report order (plans/cmux-next/chrome-parity/p04-input.md,
/// task 007). A section is in the report once its producer is registered; until then the read lists
/// it under `absent`.
public nonisolated enum DebugInputSection: String, CaseIterable, Sendable, Codable {
    /// ``InputLatencySnapshot``: histograms per kind, target, entrypoint and presentation source, and
    /// Chrome's scroll jank counts (task 002).
    case latency
    /// INP-style interaction latency (task 097).
    case interactions
    /// ``DebugInputGate``: the main-thread job gate (tasks 021, 076). No producer since sequence-manager S6 deleted
    /// the gate: the read lists it under `absent`.
    case gate
    /// Frame-aligned pointer delivery per window and consumer (task 030).
    case coalescer
    /// ``DebugInputTap``: the one input tap's subscriptions (task 011).
    case tap
    /// ``DebugInputPump``: the CEF pump's input policy (task 024).
    case pump
    /// Live scroll views and their responsive-scrolling state (task 048).
    case scrollViews = "scroll_views"
    /// Chromium's own EventLatency and ScrollJank histograms (task 091).
    case chromium
    /// ``DebugInputPrewarm``: intent prewarm's counters, hover and press apart (tasks 042, 043).
    case prewarm
}

/// The producer of one `debug.input` section. Its owner keeps the counters off the main thread (an
/// actor or atomics); ``read()`` runs on the control request's task, so a source that has main-thread
/// state copies it in one main-actor hop.
public nonisolated protocol DebugInputSource<Value>: Sendable {
    /// The section's JSON shape. Numbers and enum case names only: no user text.
    associatedtype Value: Encodable & Sendable
    /// The section this source fills.
    var section: DebugInputSection { get }
    /// The section now.
    func read() async -> Value
    /// Starts the section's counters over (`debug.input` action `reset`).
    func reset() async
}
