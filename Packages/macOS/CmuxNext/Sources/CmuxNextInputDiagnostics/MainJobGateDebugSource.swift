public import CmuxNextWakeups

/// `debug.input` section `gate` from the app's ``MainJobGate`` (DC2, DC10): one copy
/// of its atomic counters per read, nothing per job. With no gate (feature `mainJobGate` off) every
/// count is zero: nothing was held. The input-wait and non-Swift fields are not the gate's to
/// measure, so they stay absent.
///
/// ```swift
/// MainJobGateDebugSource { (NSApp as? CmuxApplication)?.jobGate?.gate }
/// ```
public nonisolated struct MainJobGateDebugSource: DebugInputSource {
    private let gate: @MainActor @Sendable () -> MainJobGate?

    /// - Parameter gate: The app's gate, or nil when the feature is off.
    public init(gate: @escaping @MainActor @Sendable () -> MainJobGate?) {
        self.gate = gate
    }

    public var section: DebugInputSection { .gate }

    public func read() async -> DebugInputGate {
        let counters = await gate()?.counters
        return Self.section(counters)
    }

    public func reset() async {
        await gate()?.resetCounters()
    }

    /// The section for `counters` (nil: no gate).
    static func section(_ counters: MainJobGate.Counters?) -> DebugInputGate {
        DebugInputGate(heldByOrigin: .init(main: counters?.heldByOrigin["main"] ?? 0, offMain: counters?.heldByOrigin["off_main"] ?? 0),
                       exemptByRule: counters?.exemptByRule ?? [:], maxInputWaitBehindJobsMilliseconds: nil,
                       jobsDeferredOverOneFrame: counters?.deferredOverOneFrame ?? 0, nonswiftBlocksWhileInputPending: nil)
    }
}
