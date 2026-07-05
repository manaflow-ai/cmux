import Foundation

/// Pure string/path math that canonicalizes and abbreviates a sidebar panel's
/// working directory for display. Lifted byte-for-byte from the legacy
/// app-target `Sidebar/SidebarPathFormatter.swift`; no AppKit/SwiftUI reach and
/// no live workspace state.
public struct SidebarPathFormatter: Sendable {
    /// The current user's home directory path, resolved once. Used as the
    /// default canonicalization root for the abbreviation helpers.
    public let homeDirectoryPath: String

    /// Creates a path formatter with the current user's home directory by default.
    public init(homeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDirectoryPath = homeDirectoryPath
    }

    /// Abbreviates `path` using this formatter's `homeDirectoryPath`.
    public func shortenedPath(_ path: String) -> String {
        shortenedPath(path, homeDirectoryPath: homeDirectoryPath)
    }

    /// Abbreviates `path` to a `~`-prefixed form when it is at or under
    /// `homeDirectoryPath`, otherwise returns the trimmed path unchanged.
    public func shortenedPath(
        _ path: String,
        homeDirectoryPath: String
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

    /// Returns the shortest single-string form using this formatter's `homeDirectoryPath`.
    public func lastSegmentPath(_ path: String) -> String {
        lastSegmentPath(path, homeDirectoryPath: homeDirectoryPath)
    }

    /// The shortest single-string form. Falls back to the abbreviated path
    /// unchanged when there are no leading segments to drop, so `/tmp` stays
    /// `/tmp` rather than becoming `…/tmp`.
    public func lastSegmentPath(
        _ path: String,
        homeDirectoryPath: String
    ) -> String {
        pathCandidates(path, homeDirectoryPath: homeDirectoryPath).last
            ?? shortenedPath(path, homeDirectoryPath: homeDirectoryPath)
    }

    /// Ordered longest → shortest using this formatter's `homeDirectoryPath`.
    public func pathCandidates(_ path: String) -> [String] {
        pathCandidates(path, homeDirectoryPath: homeDirectoryPath)
    }

    /// Ordered longest → shortest. The first entry is the full abbreviated path
    /// (with `~/` if applicable). Each subsequent entry drops one more leading
    /// segment and is prefixed with `…/`. Suitable as `ViewThatFits` candidates.
    public func pathCandidates(
        _ path: String,
        homeDirectoryPath: String
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
