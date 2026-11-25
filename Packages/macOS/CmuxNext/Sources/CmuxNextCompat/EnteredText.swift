/// What the person typed in a card's field: its description, debug description and mirror never
/// show it, so no log line, reply or `String(describing:)` of a request can carry it.
public struct EnteredText: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var description: String { "<entered>" }
    public var debugDescription: String { "<entered>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
