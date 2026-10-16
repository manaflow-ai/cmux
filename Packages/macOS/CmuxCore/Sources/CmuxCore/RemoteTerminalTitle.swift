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
        self.processTitle = Self.normalizedProcessTitle(processTitle)
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

    /// Removes a standalone animated spinner token before a remote title is
    /// compared with the previous snapshot. Cloud snapshots do not pass
    /// through the local terminal-title ingress, so leaving this normalization
    /// until the workspace projection would turn every agent animation frame
    /// into a sidebar observation.
    private static func normalizedProcessTitle(_ rawTitle: String) -> String {
        let boundedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedTitle.isEmpty else { return "" }
        let characters = Array(boundedTitle)
        guard !containsSpinnerRun(characters) else { return boundedTitle }

        var kept: [Character] = []
        var removedFrame = false
        for (index, character) in characters.enumerated() {
            let precedingIsBoundary = index == 0 || characters[index - 1].isWhitespace
            let followingIsBoundary = index == characters.count - 1 || characters[index + 1].isWhitespace
            if isSpinnerFrame(character), precedingIsBoundary, followingIsBoundary {
                removedFrame = true
            } else {
                kept.append(character)
            }
        }
        guard removedFrame else { return boundedTitle }
        return String(kept).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func containsSpinnerRun(_ characters: [Character]) -> Bool {
        var runLength = 0
        for character in characters {
            if character.unicodeScalars.count == 1,
               let scalar = character.unicodeScalars.first?.value,
               (0x2800...0x28FF).contains(scalar) || isSpinnerFrame(character) {
                runLength += 1
                if runLength >= 2 { return true }
            } else {
                runLength = 0
            }
        }
        return false
    }

    private static func isSpinnerFrame(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        switch value {
        case 0x280B, 0x2819, 0x2839, 0x2838, 0x283C,
             0x2834, 0x2826, 0x2827, 0x2807, 0x280F,
             0x2731...0x273D,
             0x25D0...0x25D3, 0x25F4...0x25F7:
            return true
        default:
            return false
        }
    }
}
