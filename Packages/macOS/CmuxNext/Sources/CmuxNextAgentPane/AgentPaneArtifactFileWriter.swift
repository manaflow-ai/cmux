import Foundation

/// Writes an agent pane artifact to an owner-only temporary directory before a browser tab opens it.
/// The injected base directory makes the path policy testable without touching the user's temp area.
public nonisolated struct AgentPaneArtifactFileWriter: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory) {
        self.directory = directory
    }

    /// Returns a private file URL, or nil if the directory or file cannot be created safely.
    public func write(_ save: AgentPaneSave) -> URL? {
        let fm = FileManager.default
        let folder = directory.appending(path: "cmux-agent-artifact-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        let file = folder.appendingPathComponent(save.suggestedName, isDirectory: false)
        guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        do {
            try Data(save.text.utf8).write(to: file)
            return file.resolvingSymlinksInPath()
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
    }
}
