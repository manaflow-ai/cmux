import Darwin
import Foundation

/// Delivers an event when any file in a private plugin snapshot changes.
///
/// The monitor is defense in depth for the launch verifier. It watches every
/// existing inode plus snapshot directories, so in-place writes, flag changes,
/// replacements, and newly-created siblings all invalidate a running child.
///
/// `DispatchSource` is the required file-watching primitive on macOS; there is
/// no Foundation async equivalent. The wrapper is unchecked-sendable because
/// its source array is immutable after initialization and callbacks carry only
/// a sendable invalidation signal; cancellation is idempotent.
public final class CmuxPluginSnapshotIntegrityMonitor: @unchecked Sendable {
    private let sources: [any DispatchSourceFileSystemObject]

    /// Creates a monitor for one private snapshot root.
    ///
    /// - Parameters:
    ///   - rootURL: The staging root whose files should be watched.
    ///   - fileManager: Filesystem provider used to enumerate the snapshot.
    ///   - onViolation: Callback delivered when a watched inode changes.
    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        onViolation: @escaping @Sendable () -> Void
    ) {
        var paths = [rootURL.standardizedFileURL]
        if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                paths.append(url)
            }
        }

        var sources: [any DispatchSourceFileSystemObject] = []
        var watchedPaths = Set<String>()
        for path in paths where watchedPaths.insert(path.path).inserted {
            let descriptor = Darwin.open(
                path.path,
                O_EVTONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler(handler: onViolation)
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
        self.sources = sources
    }

    /// Stops all filesystem sources. Repeated calls are harmless.
    public func cancel() {
        sources.forEach { $0.cancel() }
    }

    deinit {
        cancel()
    }
}
