/// One `%subscription-changed` notification from tmux control mode.
///
/// tmux leaves the middle header fields version-dependent. The subscription
/// name and the first pane target (when present) are stable enough for cmux to
/// route the notification; the remainder after ` : ` is the subscribed value.
public struct RemoteTmuxSubscriptionChange: Equatable, Sendable {
    /// The subscription name supplied to `refresh-client -B`.
    public let name: String
    /// The pane identifier that tmux supplied with the notification, if any.
    public let paneID: Int?
    /// The subscription value, preserving an empty value after the separator.
    public let value: String

    /// Parses a complete `%subscription-changed` control-mode line.
    ///
    /// - Parameter controlModeLine: One decoded control-mode line without its
    ///   trailing line ending.
    public init?(controlModeLine: String) {
        let prefix = "%subscription-changed "
        guard controlModeLine.hasPrefix(prefix) else { return nil }
        let separator = controlModeLine.range(of: " : ")
        let header = (separator.map { controlModeLine[..<$0.lowerBound] } ?? controlModeLine[...])
            .split(separator: " ")
        guard header.count >= 2 else { return nil }

        name = String(header[1])
        paneID = header.dropFirst(2).compactMap(Self.paneID(from:)).first
        value = separator.map { String(controlModeLine[$0.upperBound...]) } ?? ""
    }

    /// Extracts a sigil-prefixed pane id from one header token.
    private static func paneID(from token: Substring) -> Int? {
        guard token.first == "%" else { return nil }
        return Int(token.dropFirst())
    }
}
