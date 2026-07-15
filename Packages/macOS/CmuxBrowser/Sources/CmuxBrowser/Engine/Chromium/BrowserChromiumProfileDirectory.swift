public import Foundation

/// Builds isolated profile directories for Chromium engine process sessions.
public struct BrowserChromiumProfileDirectory {
    private let fileManager: FileManager

    /// Creates a profile-directory builder with an injectable filesystem boundary.
    ///
    /// - Parameter fileManager: The file manager that supplies the temporary directory.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the directory for one engine process session.
    ///
    /// - Parameters:
    ///   - profileID: The cmux browser profile identifier.
    ///   - surfaceID: The browser surface identifier.
    ///   - sessionID: A unique process-session identifier that prevents overlapping processes from sharing a lock file.
    /// - Returns: A temporary directory URL namespaced by profile, surface, and process session.
    public func url(profileID: UUID, surfaceID: UUID, sessionID: UUID) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("cmux-chromium", isDirectory: true)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
            .appendingPathComponent(surfaceID.uuidString, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Removes a session directory only when it has the exact cmux-owned UUID path shape.
    func removeSessionDirectoryIfOwned(_ sessionDirectory: URL) throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-chromium", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = sessionDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count == rootComponents.count + 3,
              candidateComponents.starts(with: rootComponents),
              candidateComponents.suffix(3).allSatisfy({ UUID(uuidString: $0) != nil }) else {
            return
        }
        guard fileManager.fileExists(atPath: candidate.path) else { return }

        try fileManager.removeItem(at: candidate)
    }
}
