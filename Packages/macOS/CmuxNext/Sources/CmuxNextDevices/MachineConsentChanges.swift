import CmuxNextWakeups
public import Foundation

/// acpmux's machine consent, one per OS user and shared by every app build:
/// `<the user's home>/.acpmux/machine-consent/{enrolled.json,consent.json,refusal.json}`. A change there
/// (the folder made at the first join, a file made, replaced, rewritten or removed) is one element, so the
/// app asks acpmux again (`machine_consent_get`); the files are never read for a decision. Event-driven:
/// the folder through ``FolderChanges`` (through a parent until it exists) and each file through its own
/// vnode watch, armed again after each folder change. Both are armed in ``events(armed:)`` itself, before
/// it returns and before its watch loop starts (``FolderChanges/events()`` returns once it is registered, on the folder or
/// its nearest existing parent): the folder's first, then the files', then `armed` runs, then the stream
/// yields once. So a change made from then on (the folder made, a file written) is seen by a watch, and
/// one made while they armed is read by that first ask. Ends when the consumer stops iterating.
public nonisolated struct MachineConsentChanges: Sendable {
    public static let files = ["enrolled.json", "consent.json", "refusal.json"]

    /// The folder, from the user's own password entry (`getpwuid(geteuid())`), never `HOME` or
    /// `ACPMUX_HOME`, which a launch can set to anything.
    public static var folder: URL? {
        guard let entry = getpwuid(geteuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: ".acpmux/machine-consent", directoryHint: .isDirectory)
    }

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// - Parameter armed: Runs once both watches are armed, before the first element and before the watch
    ///   loop starts (the handshake a caller can make a change in).
    public func events(armed: () -> Void = {}) async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let folder = folder
        // Armed here, in this order: the folder (FolderChanges arms in events(), not in its loop), then the
        // files, then one element, so nothing made or replaced while they armed is missed.
        let folderChanges = await FolderChanges(folders: [folder]).events()
        let first = Self.watchFiles(in: folder, continuation)
        armed()
        continuation.yield()
        // task-owner: the stream's watch loop; cancelled when the consumer stops iterating
        let loop = Task.detached(priority: .utility) {
            var watches = first
            // wakeup-allow: each pass waits for one file-system event in the consent folder, never polls
            for await _ in folderChanges {
                watches.forEach { $0.cancel() }
                watches = Self.watchFiles(in: folder, continuation)
                continuation.yield()
            }
            watches.forEach { $0.cancel() }
            continuation.finish()
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }

    /// A watch on each consent file that exists now: a write in place, a replace or a removal yields.
    private static func watchFiles(in folder: URL, _ continuation: AsyncStream<Void>.Continuation) -> [any DispatchSourceFileSystemObject] {
        files.compactMap { name in
            let fd = open(folder.appending(path: name).path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib],
                                                                   queue: .global(qos: .utility))
            source.setEventHandler { continuation.yield() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }
}
