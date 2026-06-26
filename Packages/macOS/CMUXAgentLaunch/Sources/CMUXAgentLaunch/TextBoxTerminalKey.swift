/// A named terminal key forwarded from the text box to a running terminal, whose
/// `rawValue` is the wire spelling used by the terminal key protocol (e.g. an arrow
/// key, `tab`, `backspace`, `escape`, or `return`).
public enum TextBoxTerminalKey: String, Sendable {
    /// The up arrow key (`"up"`).
    case arrowUp = "up"
    /// The down arrow key (`"down"`).
    case arrowDown = "down"
    /// The left arrow key (`"left"`).
    case arrowLeft = "left"
    /// The right arrow key (`"right"`).
    case arrowRight = "right"
    /// The tab key (`"tab"`).
    case tab
    /// The backspace key (`"backspace"`).
    case backspace
    /// The escape key (`"escape"`).
    case escape
    /// The return key (`"return"`).
    case returnKey = "return"
}
