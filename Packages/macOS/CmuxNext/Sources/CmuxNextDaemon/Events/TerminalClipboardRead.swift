import Foundation

/// `terminal-clipboard-read` (events.md): a program in `terminalID` sent an
/// OSC 52 clipboard read and its terminal host waits for the user's answer.
/// Only the one connection subscribed to the terminal gets it, and only that
/// connection answers `requestID`, once. Never carries clipboard text.
public struct TerminalClipboardRead: Decodable, Sendable, Hashable {
    /// Which clipboard the program asked for.
    public enum Location: String, Sendable, Hashable {
        case standard, selection, primary
    }

    public var requestID: String
    /// The terminal's public id (`term_…`).
    public var terminalID: String
    public var location: Location
    /// Where the daemon says the terminal runs (always local from cmux-tui);
    /// the app shows the host it knows it is connected to.
    public var host: ClipboardReadHost

    public init(requestID: String, terminalID: String, location: Location, host: ClipboardReadHost) {
        self.requestID = requestID
        self.terminalID = terminalID
        self.location = location
        self.host = host
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case terminalID = "terminal_id"
        case location, host
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(String.self, forKey: .requestID)
        terminalID = try c.decode(String.self, forKey: .terminalID)
        // An unknown location reads the standard clipboard, the one the user sees.
        location = (try c.decodeIfPresent(String.self, forKey: .location)).flatMap(Location.init(rawValue:)) ?? .standard
        host = try c.decodeIfPresent(ClipboardReadHost.self, forKey: .host) ?? ClipboardReadHost(kind: .remote)
    }
}
