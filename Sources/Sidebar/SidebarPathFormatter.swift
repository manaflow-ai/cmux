import Foundation

enum SidebarPathFormatter {
    static let homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path

    static func shortenedPath(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == homeDirectoryPath {
            return "~"
        }
        if trimmed.hasPrefix(homeDirectoryPath + "/") {
            return "~" + trimmed.dropFirst(homeDirectoryPath.count)
        }
        return trimmed
    }

    // The shortest single-string form. Falls back to the abbreviated path
    // unchanged when there are no leading segments to drop, so `/tmp` stays
    // `/tmp` rather than becoming `…/tmp`.
    static func lastSegmentPath(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> String {
        pathCandidates(path, homeDirectoryPath: homeDirectoryPath).last
            ?? shortenedPath(path, homeDirectoryPath: homeDirectoryPath)
    }

    // Just the folder name — sidebar rows lead with project identity, so the
    // bare last segment ("chat") beats a full path ("~/Code/linktree/chat").
    static func bareLastSegment(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> String {
        let abbreviated = shortenedPath(path, homeDirectoryPath: homeDirectoryPath)
        guard abbreviated != "~", abbreviated != "/" else { return abbreviated }
        let parts = abbreviated.split(separator: "/", omittingEmptySubsequences: true)
        return parts.last.map(String.init) ?? abbreviated
    }

    // Ordered longest → shortest. The first entry is the full abbreviated path
    // (with `~/` if applicable). Each subsequent entry drops one more leading
    // segment and is prefixed with `…/`. Suitable as `ViewThatFits` candidates.
    static func pathCandidates(
        _ path: String,
        homeDirectoryPath: String = Self.homeDirectoryPath
    ) -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let abbreviated = shortenedPath(trimmed, homeDirectoryPath: homeDirectoryPath)
        guard !abbreviated.isEmpty else { return [] }
        if abbreviated == "~" || abbreviated == "/" { return [abbreviated] }

        let prefixLength: Int = {
            if abbreviated.hasPrefix("~/") { return 2 }
            if abbreviated.hasPrefix("/") { return 1 }
            return 0
        }()
        let suffix = String(abbreviated.dropFirst(prefixLength))
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var candidates = [abbreviated]
        guard parts.count > 1 else { return candidates }
        for dropCount in 1..<parts.count {
            let remainder = parts[dropCount...].joined(separator: "/")
            candidates.append("…/\(remainder)")
        }
        return candidates
    }
}
