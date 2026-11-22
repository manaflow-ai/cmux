import Foundation

/// A key the person typed into the card's private field. It never shows its value: not in
/// `description`, `debugDescription`, a dump, a log or an equality failure message, so a key cannot
/// reach a transcript by being printed. The host hands ``reveal()`` to the daemon and drops it.
public struct McpConnectKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { value.isEmpty }
    /// The value, for the one send to the daemon.
    public func reveal() -> String { value }
    public var description: String { "McpConnectKey(••••••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
