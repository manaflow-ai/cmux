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
    /// A stream element emitted when a watched inode may have changed.
    public typealias Event = Void

    private let sources: [any DispatchSourceFileSystemObject]
    private let continuation: AsyncStream<Event>.Continuation

    /// Creates a monitor for one private snapshot root.
    ///
    /// - Parameters:
    ///   - rootURL: The staging root whose files should be watched.
    ///   - additionalURLs: Individual external files (such as a shebang
    ///     interpreter) whose bytes participate in the launch contract.
    ///   - fileManager: Filesystem provider used to enumerate the snapshot.
    ///
    /// Consume ``events`` to receive invalidation signals without polling.
    public init(
        rootURL: URL,
        additionalURLs: [URL] = [],
        fileManager: FileManager = .default
    ) {
        let (events, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = continuation
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
        let canonicalAdditionalURLs = additionalURLs.map { url -> URL in
            let standardized = url.standardizedFileURL
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let resolved = standardized.path.withCString { pointer in
                Darwin.realpath(pointer, &buffer)
            }
            guard resolved != nil else { return standardized }
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            let path = String(
                decoding: buffer[..<length].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        }
        paths.append(contentsOf: canonicalAdditionalURLs)

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
                // Do not subscribe to `.attrib`: reading a file can update
                // last-used metadata and create a self-sustaining verify/hash
                // loop. Any rewrite after an owner clears the immutable flag
                // still emits `.write`/`.extend` and is caught here.
                eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler {
                continuation.yield(())
            }
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
        self.sources = sources
    }

    /// The event-driven invalidation stream for this snapshot.
    public nonisolated let events: AsyncStream<Event>

    /// Stops all filesystem sources. Repeated calls are harmless.
    public func cancel() {
        sources.forEach { $0.cancel() }
        continuation.finish()
    }

    deinit {
        cancel()
    }
}
