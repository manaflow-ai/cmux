import Foundation

/// The raw tmux pane title and host values used to recognize its default title.
public struct RemoteTmuxPaneTitleMetadata: Equatable, Sendable {
    /// A control character that tmux leaves untouched in format expansions.
    public static let fieldSeparator: Character = "\u{1f}"

    /// The raw title emitted by tmux for the pane.
    public let title: String
    /// The full host name emitted by tmux for the pane.
    public let host: String
    /// The short host name emitted by tmux for the pane.
    public let hostShort: String

    /// Parses the title, full host, and short host emitted by a tmux format.
    ///
    /// - Parameter wireValue: The three fields separated by ``fieldSeparator``.
    public init?(wireValue: String) {
        let fields = wireValue.split(
            separator: Self.fieldSeparator,
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard fields.count == 3 else { return nil }
        self.init(
            title: String(fields[0]),
            host: String(fields[1]),
            hostShort: String(fields[2])
        )
    }

    /// Creates metadata from already-separated tmux format values.
    ///
    /// - Parameters:
    ///   - title: The raw pane title.
    ///   - host: The full host name used by tmux's default title.
    ///   - hostShort: The short host name used by tmux's default title.
    public init(title: String, host: String, hostShort: String) {
        self.title = title
        self.host = host
        self.hostShort = hostShort
    }

    /// Returns a non-default title, or `nil` when tmux supplied its host title.
    public var intentionalTitle: String? {
        let title = Self.normalized(title)
        guard !title.isEmpty else { return nil }

        let defaultHosts = [host, hostShort]
            .map(Self.normalized)
            .filter { !$0.isEmpty }
        guard !defaultHosts.isEmpty else { return nil }
        guard !defaultHosts.contains(where: {
            $0.caseInsensitiveCompare(title) == .orderedSame
        }) else {
            return nil
        }
        return title
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
