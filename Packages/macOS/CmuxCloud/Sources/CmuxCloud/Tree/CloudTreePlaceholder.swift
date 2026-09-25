/// A one-line explanatory row under a machine.
public struct CloudTreePlaceholder: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case dimmed
        case connecting
        case error
    }

    public let text: String
    public let style: Style
    /// Only wake placeholders set this. Empty resource categories remain inert.
    public let opensMachine: Bool
    public init(text: String, style: Style, opensMachine: Bool = false) {
        self.text = text
        self.style = style
        self.opensMachine = opensMachine
    }
}
