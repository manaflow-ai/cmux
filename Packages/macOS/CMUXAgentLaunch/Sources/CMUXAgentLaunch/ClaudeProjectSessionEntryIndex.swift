import Foundation

/// Which folders under a Claude `projects/` directory can hold files for a
/// session, built from one listing of each folder.
///
/// A session's transcript is `<folder>/<id>.jsonl` or sits under
/// `<folder>/<id>/`, so a folder with neither entry holds nothing for it.
/// Callers that check many sessions probe only the folders this index
/// returns. Probing every folder for every session costs sessions x folders.
///
/// The index never rules out a folder the file system would match. File names
/// are compared the way a case-insensitive volume compares ASCII, and anything
/// it can't compare that way (a non-ASCII session id or entry name, a folder
/// that could not be listed) falls back to "check this folder".
public struct ClaudeProjectSessionEntryIndex: Sendable {
    private var projectDirs: [String] = []
    private var positionsBySessionId: [String: [Int]] = [:]
    private var uncertainPositions: [Int] = []

    /// Creates an empty index.
    public init() {}

    /// The session ids the entries of one project folder can belong to: each
    /// name and, for a `.jsonl` file, the name without that suffix, lowercased.
    ///
    /// Returns nil when a name is not ASCII. Volumes fold such names in ways
    /// `lowercased()` does not, so the folder has to be checked for every
    /// session instead.
    public static func sessionIds(entryNames: [String]) -> Set<String>? {
        var sessionIds: Set<String> = []
        let suffix = ".jsonl"
        for entryName in entryNames {
            guard entryName.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
            let name = entryName.lowercased()
            sessionIds.insert(name)
            if name.hasSuffix(suffix) {
                sessionIds.insert(String(name.dropLast(suffix.count)))
            }
        }
        return sessionIds
    }

    /// Adds the next folder of the `projects/` listing with the session ids
    /// from ``sessionIds(entryNames:)``. Pass nil for a folder that could not
    /// be listed or compared; every session is then checked against it.
    public mutating func add(projectDir: String, sessionIds: Set<String>?) {
        let position = projectDirs.count
        projectDirs.append(projectDir)
        guard let sessionIds else {
            uncertainPositions.append(position)
            return
        }
        for sessionId in sessionIds {
            positionsBySessionId[sessionId, default: []].append(position)
        }
    }

    /// The folders to check for `sessionId`, in the order they were added.
    public func projectDirs(sessionId: String) -> [String] {
        guard sessionId.utf8.allSatisfy({ $0 < 0x80 }) else { return projectDirs }
        let listed = positionsBySessionId[sessionId.lowercased()] ?? []
        guard !uncertainPositions.isEmpty else { return listed.map { projectDirs[$0] } }
        return (listed + uncertainPositions).sorted().map { projectDirs[$0] }
    }
}
