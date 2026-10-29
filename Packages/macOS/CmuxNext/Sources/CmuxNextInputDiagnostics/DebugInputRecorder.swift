/// The on-request recorders of `debug.input`, each its own action: `hops` (task 022), `dirty`
/// (task 093), `hittest` (task 098) and `late_keys` (key-downs dispatched more than 100 ms after their OS time, with
/// the path that held them).
public nonisolated enum DebugInputRecorderKind: String, CaseIterable, Sendable {
    case hops, dirty, hittest
    case lateKeys = "late_keys"
}

/// The producer of one on-request `debug.input` action (``DebugInputRecorderKind``). The recorder
/// owns its rows' JSON shape.
public nonisolated protocol DebugInputRecorder<Rows>: Sendable {
    associatedtype Rows: Encodable & Sendable
    /// The action this recorder answers.
    var kind: DebugInputRecorderKind { get }
    /// The rows now: since launch, or since the last reset.
    func rows(sinceLaunch: Bool) async -> Rows
    /// Starts the recorder over and removes what it installed (`debug.input` action `reset`).
    func reset() async
}
