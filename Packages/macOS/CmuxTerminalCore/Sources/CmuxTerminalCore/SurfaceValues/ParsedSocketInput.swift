public import Foundation

/// The classification of one parsed chunk of socket-delivered input.
public enum ParsedSocketInput: Sendable {
    /// Plain bytes forwarded as user input.
    case rawBytes(Data)
    /// A complete terminal string control sequence such as OSC, DCS, PM, or APC.
    case terminalBytes(Data)
    /// A control character translated into a named-key press.
    case key(PendingKeyEvent)
}
