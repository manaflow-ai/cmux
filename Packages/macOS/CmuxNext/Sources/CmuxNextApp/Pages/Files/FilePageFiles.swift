import Foundation

/// Watches a file page's file and reports its new content (nil: deleted) through the callback
/// it was made with. ``FileChangeWatch`` on this Mac, ``RemoteFileChangeWatch`` on a Cloud machine.
protocol FilePageWatching: AnyObject {
    /// The hash last reported (or read at open); a read with the same hash reports nothing.
    var knownHash: String? { get set }
    func start()
    func stop()
}

extension FileChangeWatch: FilePageWatching {}

/// Where a file page's file lives (#25581): this Mac's disk, or the machine of the pane the tab
/// opened in. A tab in a Cloud workspace reads, saves and watches the file on the VM, never a
/// file of the same path on this Mac.
protocol FilePageFiles: AnyObject {
    /// The file is on this Mac: its folder's images and links, its git remote, recents, drafts and
    /// the pickers read this Mac's disk. Nothing local is read for a file that is not.
    var isLocal: Bool { get }
    /// The path every grant compares: links resolved on this Mac; `.` and `..` removed elsewhere.
    func canonical(_ url: URL) -> URL
    func read(_ url: URL, inWorkspace: Bool) async throws(FileOpenFailure) -> FileSnapshot
    /// `cmux.<page>.save`: writes `text` when the file's hash is still `baseHash`.
    func save(_ text: String, to url: URL, baseHash: String?, inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult
    /// A watch of `url`. `onUnavailable` hears the machine go away (its reason) and come back
    /// (nil); this Mac's disk never goes away.
    func watch(_ url: URL, inWorkspace: @escaping () -> Bool, clock: any Clock<Duration>,
               onChange: @escaping (FileSnapshot?) -> Void, onUnavailable: @escaping (String?) -> Void) -> any FilePageWatching
}

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
        try FileDocument.read(url, inWorkspace: inWorkspace)
    }

    @concurrent private static func write(_ text: String, to url: URL, baseHash: String?,
                                          inWorkspace: Bool) async throws(FileSaveFailure) -> FileSaveResult {
        try FileDocument.save(text, to: url, baseHash: baseHash, inWorkspace: inWorkspace)
    }
}
