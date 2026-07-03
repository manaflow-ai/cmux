import Foundation

/// Opening marker for a Markdown fenced code block.
struct FenceMarker: Equatable, Sendable {
    /// The fence character, either a backtick or tilde.
    var character: Character
    /// Number of repeated fence characters in the opening marker.
    var count: Int

    init?(trimmedLine: Substring) {
        guard let first = trimmedLine.first, first == "`" || first == "~" else {
            return nil
        }
        let marker = trimmedLine.prefix { $0 == first }
        guard marker.count >= 3 else { return nil }
        character = first
        count = marker.count
    }

    init?(closingLine trimmedLine: Substring) {
        guard let marker = FenceMarker(trimmedLine: trimmedLine) else {
            return nil
        }
        let rest = trimmedLine.dropFirst(marker.count)
        guard rest.allSatisfy({ $0 == " " || $0 == "\t" }) else {
            return nil
        }
        self = marker
    }

    func closes(_ opening: FenceMarker) -> Bool {
        character == opening.character && count >= opening.count
    }
}
