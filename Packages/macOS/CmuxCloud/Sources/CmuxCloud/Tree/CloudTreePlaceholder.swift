/// A one-line explanatory row under a machine.
public struct CloudTreePlaceholder: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case dimmed
        case connecting
        case error
        /// An action row that opens the New Machine sheet.
        case createMachine
        /// Plain guidance with no icon or action, like "No cloud machines yet".
        case empty
    }

    /// The next step an empty category offers, so "No terminals yet" is not a
    /// dead end: the row's click runs it and the row shows its title.
    public enum Action: Equatable, Sendable {
        case newTerminal
        case newWorkspace
    }

    public let text: String
    public let style: Style
    /// Only wake placeholders set this. Empty resource categories remain inert.
    public let opensMachine: Bool
    public let portStatus: CloudPortsStatusPresentation?
    public let action: Action?
    public init(
        text: String,
        style: Style,
        opensMachine: Bool = false,
        portStatus: CloudPortsStatusPresentation? = nil,
        action: Action? = nil
    ) {
        self.text = text
        self.style = style
        self.opensMachine = opensMachine
        self.portStatus = portStatus
        self.action = action
    }
}
