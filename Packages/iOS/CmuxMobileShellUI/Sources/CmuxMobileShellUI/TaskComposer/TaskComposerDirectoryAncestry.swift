import Foundation

/// Builds the navigation-stack seed for the directory picker: every ancestor
/// of the selected folder, ordered root-first, so the standard back button
/// walks up the folder hierarchy one level at a time.
enum TaskComposerDirectoryAncestry {
    /// The back stack can show at most this many seeded levels; deeper paths
    /// keep their deepest folders because those are the ones a user browses.
    static let maxSeededDepth = 12

    static func chain(for path: String) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["~"] }

        let root: String
        let remainder: Substring
        if trimmed.hasPrefix("/") {
            root = "/"
            remainder = trimmed.dropFirst()
        } else if trimmed == "~" || trimmed.hasPrefix("~/") {
            root = "~"
            remainder = trimmed.dropFirst(trimmed == "~" ? 1 : 2)
        } else {
            // A relative or otherwise opaque path cannot be decomposed on the
            // phone; browse it as a single screen and let the Mac resolve it.
            return [trimmed]
        }

        var chain = [root]
        var current = root == "/" ? "" : root
        for component in remainder.split(separator: "/") {
            current += "/" + component
            chain.append(current)
        }
        if chain.count > maxSeededDepth {
            chain = Array(chain.suffix(maxSeededDepth))
        }
        return chain
    }
}
