/// `debug.mainJobGate` in cmux-next.json: whether main-actor jobs wait behind a person's pending
/// input (feature `mainJobGate`). Off, the runtime hook is not installed.
///
/// ```jsonc
/// "debug": {
///   "mainJobGate": true   // hold main-actor jobs behind pending input (with the feature on)
/// }
/// ```
///
/// Read from the snapshot's document, not stored: a missing or non-boolean value is the default.
public nonisolated struct MainJobGateSettings: Sendable, Equatable {
    public static let enabledPath = ["debug", "mainJobGate"]
    public static let enabledDefault = true

    public var enabled = Self.enabledDefault

    public init() {}

    /// The value in `root`; a non-boolean value is the default.
    public init(_ root: JSONValue) {
        if let value = root.value(at: Self.enabledPath)?.boolValue { enabled = value }
    }
}

extension CmuxConfigSnapshot {
    /// `debug.mainJobGate` (``MainJobGateSettings``).
    public var mainJobGate: MainJobGateSettings { MainJobGateSettings(root) }
}
