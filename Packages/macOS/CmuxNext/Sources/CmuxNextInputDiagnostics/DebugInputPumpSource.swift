/// `debug.input` section `pump` from the CEF message pump's input policy (p04-input.md task 024). The
/// pump keeps its counters on the main thread; a read is one main-actor copy of them, nothing per pass.
/// The App passes the browser engine's reads, so this package needs no browser dependency.
///
/// ```swift
/// DebugInputPumpSource(read: { [cef] in cef.pumpStats.map { DebugInputPump(...) } }, reset: { [cef] in cef.resetPumpInputCounters() })
/// ```
public nonisolated struct DebugInputPumpSource: DebugInputSource {
    private let readCounters: @MainActor @Sendable () -> DebugInputPump?
    private let resetCounters: @MainActor @Sendable () -> Void

    /// - Parameters:
    ///   - read: The pump's input counters; nil before Chromium runs in this process.
    ///   - reset: Starts them over.
    public init(read: @escaping @MainActor @Sendable () -> DebugInputPump?, reset: @escaping @MainActor @Sendable () -> Void) {
        readCounters = read
        resetCounters = reset
    }

    public var section: DebugInputSection { .pump }

    /// Zero counters while no in-process pump runs (a Chromium host process, or Chromium not started).
    public func read() async -> DebugInputPump {
        await readCounters() ?? DebugInputPump(passesWhileInputPending: [:], deferredForInput: 0, passMillisecondsP99: 0)
    }

    public func reset() async {
        await resetCounters()
    }
}
