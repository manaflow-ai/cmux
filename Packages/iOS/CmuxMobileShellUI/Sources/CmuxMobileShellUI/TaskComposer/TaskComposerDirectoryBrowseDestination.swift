#if os(iOS)
import Foundation

/// One folder level on the directory picker's navigation stack.
struct TaskComposerDirectoryBrowseDestination: Hashable {
    let path: String

    /// The back stack can show at most this many seeded levels; deeper paths
    /// keep their deepest folders because those are the ones a user browses.
    static let maxSeededDepth = 12

    /// The navigation-stack seed for a selected folder: every ancestor of
    /// `path`, ordered root-first, so the standard back button walks up the
    /// folder hierarchy one level at a time.
    static func ancestry(for path: String) -> [TaskComposerDirectoryBrowseDestination] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [Self(path: "~")] }

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
            return [Self(path: trimmed)]
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
        return chain.map(Self.init)
    }
}
#endif
