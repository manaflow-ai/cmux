import CmuxNextFiles
import Foundation

extension FileChangeWatch: FilePageWatching {}

/// This Mac's disk: ``FileDocument`` and ``FileChangeWatch``.
final class LocalFilePageFiles: FilePageFiles {
    static let shared = LocalFilePageFiles()

    var isLocal: Bool { true }

    func canonical(_ url: URL) -> URL { Self.resolved(url) }

    /// The path with this Mac's symlinks resolved.
    nonisolated static func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    func read(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> FileSnapshot {
        try await Self.read(url, inWorkspace: inWorkspace)
    }

    func save(_ text: String, to url: URL, baseHash: String?, inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        try await Self.write(text, to: url, baseHash: baseHash, inWorkspace: inWorkspace)
    }

    func watch(_ url: URL, inWorkspace: @escaping () -> Bool, clock: any Clock<Duration>,
               onChange: @escaping (FileSnapshot?) -> Void, onUnavailable: @escaping (String?) -> Void) -> any FilePageWatching {
        FileChangeWatch(url: url, inWorkspace: inWorkspace, clock: clock, onChange: onChange)
    }

    @concurrent private static func read(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> FileSnapshot {
        try FileDocument().read(url, inWorkspace: inWorkspace)
    }

    @concurrent private static func write(_ text: String, to url: URL, baseHash: String?,
                                          inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        try FileDocument().save(text, to: url, baseHash: baseHash, inWorkspace: inWorkspace)
    }
}
