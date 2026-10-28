public import Foundation
import CmuxNextCompat

/// Changes to the contents of some folders as an `AsyncStream`: one element per burst of
/// file-system events, never a poll (plans/cmux-next/idle-wakeups.md). A folder that does not
/// exist yet is watched through its nearest existing parent (a stand-in) and is watched itself
/// once made.
///
/// A stand-in's own changes are not the folder's: a missing `Backgrounds` folder is watched
/// through the app's Application Support folder, where the app writes its own files on every
/// prompt. An event from a stand-in yields only when a missing folder now exists (the watches
/// move down to it); otherwise it is dropped, and counted in the ledger under
/// `FolderChanges/stand-in`. Each element is counted under `FolderChanges/change`.
///
/// Each element comes after the watch is armed again when it had to move, so a change between
/// two elements is either seen by the watch or happened before the element, and the consumer's
/// work for the element (re-reading the folders) covers it.
///
/// ```swift
/// for await _ in FolderChanges(folders: [wallpapers, userImages]).events() { rebuild() }
/// ```
public struct FolderChanges: Sendable {
    /// The folders whose contents matter.
    public let folders: [URL]
    private let ledger: WakeupLedger
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The line that made the watch, for the arm census.
    private let site: ArmCensus.Site
    #endif

    /// - Parameters:
    ///   - folders: The folders whose contents matter; missing ones are watched through a parent.
    ///   - ledger: Where the watch counts its wakes. In Debug and bench builds its ``ArmCensus`` also gets the watch's
    ///     launch arm and first change (startup-queue.py arms, p08-startup-085).
    ///   - file: The line that made the watch, named by the arm census (leave the default).
    ///   - line: See `file`.
    public init(folders: [URL], ledger: WakeupLedger = .shared, file: StaticString = #fileID, line: UInt = #line) {
        self.folders = folders
        self.ledger = ledger
        #if DEBUG || CMUX_BENCH_HOOKS
        site = ArmCensus.Site(file: file, line: line)
        #endif
    }

    /// One element after each burst of changes in any watched folder. Ends when the consumer
    /// stops iterating (the watches are cancelled with it).
    public func events() -> AsyncStream<Void> {
        let targets = folders.map(\.path)
        let ledger = ledger
        #if DEBUG || CMUX_BENCH_HOOKS
        let site = site
        #endif
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // task-owner: the stream's watch loop; cancelled when the consumer stops iterating
        let loop = Task.detached(priority: .utility) {
            var armed = Self.arm(targets)
            #if DEBUG || CMUX_BENCH_HOOKS
            var census = ArmCensusEntry()
            census.armed(in: ledger.armCensus, .watcher, owner: "FolderChanges", site: site)
            #endif
            // wakeup-allow: each pass waits for one file-system event in a watched folder, never polls
            while !Task.isCancelled {
                var iterator = armed.events.makeAsyncIterator()
                guard let event = await iterator.next() else { break }
                #if DEBUG || CMUX_BENCH_HOOKS
                // Every event woke the process, a stand-in's own write included: the census's first fire is the
                // first wake the ledger counts, under `change` or `stand-in`.
                census.fired(in: ledger.armCensus)
                #endif
                let now = Set(targets.map(nearestExistingFolder(of:)))
                let moved = now != armed.paths || event.flags.contains(.delete) || event.flags.contains(.rename)
                if !moved, !targets.contains(event.path) {
                    // A stand-in's own write: no watched folder appeared, so nothing of ours changed.
                    ledger.record("FolderChanges", reason: "stand-in")
                    continue
                }
                if moved {
                    let next = Self.arm(targets)
                    armed.cancel()
                    armed = next
                    #if DEBUG || CMUX_BENCH_HOOKS
                    census.armed(in: ledger.armCensus, .watcher, owner: "FolderChanges", site: site)
                    #endif
                }
                ledger.record("FolderChanges", reason: "change")
                continuation.yield()
            }
            armed.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }

    /// Watches the nearest existing folder of each of `targets`.
    private static func arm(_ targets: [String]) -> FolderWatch {
        let paths = Set(targets.map(nearestExistingFolder(of:)))
        let (events, continuation) = AsyncStream<FolderWatch.Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        // DispatchSource for file watching: no Foundation async equivalent (idle-wakeups.md).
        let sources = paths.compactMap { folder -> (any DispatchSourceFileSystemObject)? in
            let fd = blockingOpen(folder, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link],
                                                                   queue: .global(qos: .utility))
            // The handler holds its source until cancel releases the handlers (FolderWatch.cancel).
            source.setEventHandler { continuation.yield(FolderWatch.Event(path: folder, flagBits: source.data.rawValue)) }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
        return FolderWatch(paths: paths, events: events, sources: sources, finish: { continuation.finish() })
    }
}

/// The deepest existing folder on `path`, `path` itself included (`/` at worst).
private func nearestExistingFolder(of path: String) -> String {
    var directory = path
    var isFolder: ObjCBool = false
    while !(FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder) && isFolder.boolValue),
          directory != "/", !directory.isEmpty {
        directory = (directory as NSString).deletingLastPathComponent
    }
    return directory.isEmpty ? "/" : directory
}
