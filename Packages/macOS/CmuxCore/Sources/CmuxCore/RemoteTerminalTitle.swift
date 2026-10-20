import Foundation

/// Resolves a process title and its placement-local names without losing distinct aliases.
public struct RemoteTerminalTitle: Sendable {
    /// The normalized process title, independent of any user-assigned view name.
    public let processTitle: String
    private let viewNames: [String?]

    /// Creates a title projection from authoritative terminal and tab metadata.
    /// - Parameters:
    ///   - processTitle: The terminal's PTY-derived title.
    ///   - viewNames: Names of all current tab views; nil means an unnamed view.
    public init(processTitle: String, viewNames: [String?] = []) {
        self.processTitle = processTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.viewNames = viewNames.map { name in
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The common explicit name when every view agrees, otherwise the process title.
    ///
    /// A terminal-wide rename labels the inventory row as well as all its views.
    /// Different placement names remain independent; the inventory then identifies
    /// their common process rather than arbitrarily choosing one of those aliases.
    public var poolTitle: String {
        guard let first = viewNames.first, let name = first,
              viewNames.allSatisfy({ $0 == name }) else { return processTitle }
        return name
    }
}
