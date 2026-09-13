/// A one-line explanatory row under a machine.
struct CloudTreePlaceholder: Equatable {
    enum Style: Equatable {
        case dimmed
        case connecting
        case error
    }

    let text: String
    let style: Style
    /// Only wake placeholders set this. Empty resource categories remain inert.
    let opensMachine: Bool
    /// A successful empty discovery can offer optional private-network setup.
    let isEmptyPorts: Bool

    init(text: String, style: Style, opensMachine: Bool = false, isEmptyPorts: Bool = false) {
        self.text = text
        self.style = style
        self.opensMachine = opensMachine
        self.isEmptyPorts = isEmptyPorts
    }
}

