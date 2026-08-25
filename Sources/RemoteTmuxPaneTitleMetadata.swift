import Foundation

/// Identifies one pane-rectangle snapshot so an older reply cannot overwrite a
/// newer live pane-title subscription event.
struct RemoteTmuxPaneTitleSnapshotKey: Hashable, Sendable {
    let windowId: Int
    let generation: Int
}

/// The raw tmux pane title and the host values used to recognize its default.
struct RemoteTmuxPaneTitleMetadata: Equatable, Sendable {
    /// A control character that tmux leaves untouched in format expansions.
    static let fieldSeparator: Character = "\u{1f}"

    let title: String
    let host: String
    let hostShort: String

    /// Parses the title, full host, and short host emitted by a tmux format.
    init?(wireValue: String) {
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
    init(title: String, host: String, hostShort: String) {
        self.title = title
        self.host = host
        self.hostShort = hostShort
    }

    /// Returns a non-default title, or `nil` when tmux supplied its host title.
    var intentionalTitle: String? {
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
