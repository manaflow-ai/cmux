public import CmuxNextFiles
public import Foundation

extension FileChangeWatch: FilePageWatching {}

/// This Mac's disk: ``FileDocument`` and ``FileChangeWatch``. It holds nothing, so each file page
/// may make its own.
public final class LocalFilePageFiles: FilePageFiles {
    /// This Mac's files.
    public init() {}

    public var isLocal: Bool { true }

    public func canonical(_ url: URL) -> URL { Self.resolved(url) }

    /// The path with this Mac's symlinks resolved.
    public nonisolated static func resolved(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    public func read(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> FileSnapshot {
        try await Self.read(url, inWorkspace: inWorkspace)
    }

    public func save(_ text: String, to url: URL, baseHash: String?, inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        try await Self.write(text, to: url, baseHash: baseHash, inWorkspace: inWorkspace)
    }

    public func watch(_ url: URL, inWorkspace: @escaping () -> Bool, clock: any Clock<Duration>,
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
