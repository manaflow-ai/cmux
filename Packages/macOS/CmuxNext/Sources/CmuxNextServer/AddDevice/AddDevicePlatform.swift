/// The kind of new device the "Set up a new device" way shows the line for.
public nonisolated enum AddDevicePlatform: String, CaseIterable, Equatable, Sendable {
    /// A Mac or a Linux computer (one shell line).
    case macOrLinux
    case windows
    /// An iPhone: no line; the phone signs in and asks to connect.
    case phone

    /// The line to run on the new computer: install cmux, then show its pairing code and words.
    /// Nil for a phone.
    public var setupLine: String? {
        switch self {
        case .macOrLinux:
            "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/cmux server pair"
        case .windows:
            "irm https://cmux.com/tui/install-static.ps1 | iex; cmux server pair"
        case .phone:
            nil
        }
    }
}
