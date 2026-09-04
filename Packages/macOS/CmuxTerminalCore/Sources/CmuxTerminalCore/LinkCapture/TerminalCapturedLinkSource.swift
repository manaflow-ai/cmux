/// The capture path that found a terminal-emitted URL.
public enum TerminalCapturedLinkSource: String, Codable, Sendable {
    /// An OSC-8 hyperlink URI from the raw byte stream.
    case osc8
    /// A plain URL detected in the reassembled logical output line.
    case detected
}
