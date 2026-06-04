public import Foundation

/// What the input host should send to the terminal for one resolved input.
public enum TerminalInputEmission: Equatable, Sendable {
    /// Send the string through the plain text path.
    case sendText(String)
    /// Send a raw VT byte sequence through the escape-sequence path.
    case sendBytes(Data)
}
