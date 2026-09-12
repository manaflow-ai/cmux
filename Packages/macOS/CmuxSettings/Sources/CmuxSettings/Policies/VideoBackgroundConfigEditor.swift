import Darwin
import Foundation

/// Synchronously edits the `terminal.videoBackground` object in `cmux.json`.
///
/// The GUI settings flow normally writes through ``JSONConfigStore`` or the
/// UserDefaults importer. The CLI needs the same shape without an async actor
/// hop, so this small value type provides a shared, JSONC-tolerant mutation
/// path. Writes are atomic and follow a `cmux.json` symlink rather than
/// replacing the link itself.
public struct VideoBackgroundConfigEditor: Sendable {
    /// A partial update to the video-background object.
    public struct Mutation: Sendable {
        /// New enabled state, or `nil` to leave it unchanged.
        public var enabled: Bool?
        /// New legacy single source, or `nil` to leave it unchanged.
        public var source: String?
        /// New ordered queue. An empty array explicitly clears the queue.
        public var queue: [String]?
        /// New mute state, or `nil` to leave it unchanged.
        public var muted: Bool?
        /// New quality value/alias, or `nil` to leave it unchanged.
        public var quality: String?
        /// New volume (`0...1`), or `nil` to leave it unchanged.
        public var volume: Double?
        /// New dim opacity, or `nil` to leave it unchanged.
        public var dimOpacity: Double?

        /// Creates a partial update.
        public init(
            enabled: Bool? = nil,
            source: String? = nil,
            queue: [String]? = nil,
            muted: Bool? = nil,
            quality: String? = nil,
            volume: Double? = nil,
            dimOpacity: Double? = nil
        ) {
            self.enabled = enabled
            self.source = source
            self.queue = queue
            self.muted = muted
            self.quality = quality
            self.volume = volume
            self.dimOpacity = dimOpacity
        }
    }

    /// Values currently present in the config file. Missing fields remain
    /// `nil`, allowing callers to distinguish an inherited/default value.
    public struct Snapshot: Equatable, Sendable {
        /// File-managed enabled value, if present.
        public let enabled: Bool?
        /// File-managed legacy source, if present.
        public let source: String?
        /// File-managed queue, if present.
        public let queue: [String]?
        /// File-managed mute value, if present.
        public let muted: Bool?
        /// File-managed quality value, if present.
        public let quality: String?
        /// File-managed volume, if present and finite.
        public let volume: Double?
        /// File-managed dim opacity, if present and finite.
        public let dimOpacity: Double?

        /// Creates a snapshot value.
        public init(
            enabled: Bool?,
            source: String?,
            queue: [String]?,
            muted: Bool?,
            quality: String?,
            volume: Double?,
            dimOpacity: Double?
        ) {
            self.enabled = enabled
            self.source = source
            self.queue = queue
            self.muted = muted
            self.quality = quality
            self.volume = volume
            self.dimOpacity = dimOpacity
        }
    }

    /// The config file edited by this instance.
    public let fileURL: URL

    /// Creates an editor for `fileURL`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Reads the current video-background values.
    ///
    /// JSONC comments and trailing commas are accepted. A missing file is
    /// treated as an empty config; malformed existing JSON is reported.
    public func read() throws -> Snapshot {
        try withExclusiveFileLock { targetURL in
            let root = try readRoot(from: targetURL)
            return snapshot(from: root)
        }
    }

    /// Applies `mutation`, writes atomically, and returns the resulting values.
    ///
    /// Existing keys outside `terminal.videoBackground` are preserved. The
    /// nested object is retained when fields are explicitly cleared so the
    /// user's intent is visible in `cmux.json`.
    @discardableResult
    public func update(_ mutation: Mutation) throws -> Snapshot {
        try withExclusiveFileLock { targetURL in
            var root = try readRoot(from: targetURL)
            if let existingTerminal = root["terminal"], !(existingTerminal is [String: Any]) {
                throw JSONConfigStoreReadError.notADictionary
            }
            var terminal = root["terminal"] as? [String: Any] ?? [:]
            if let existingVideo = terminal["videoBackground"], !(existingVideo is [String: Any]) {
                throw JSONConfigStoreReadError.notADictionary
            }
            var video = terminal["videoBackground"] as? [String: Any] ?? [:]

            if let enabled = mutation.enabled { video["enabled"] = enabled }
            if let source = mutation.source {
                video["source"] = source.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let queue = mutation.queue {
                video["queue"] = VideoBackgroundSettings().normalizedQueue(queue)
            }
            if let muted = mutation.muted { video["muted"] = muted }
            if let quality = mutation.quality {
                video["quality"] = VideoBackgroundSettings().normalizedQuality(quality)
            }
            if let volume = mutation.volume,
               volume.isFinite {
                video["volume"] = VideoBackgroundSettings().normalizedVolume(volume)
            }
            if let dimOpacity = mutation.dimOpacity,
               dimOpacity.isFinite {
                video["dimOpacity"] = VideoBackgroundSettings().normalizedDimOpacity(dimOpacity)
            }

            terminal["videoBackground"] = video
            root["terminal"] = terminal
            try writeRoot(root, to: targetURL)
            return snapshot(from: root)
        }
    }

    private func readRoot(from readURL: URL) throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: readURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return [:]
        } catch {
            throw error
        }
        guard !data.isEmpty else { return [:] }
        let sanitized = try JSONCSanitizer().sanitize(data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
        guard let root = object as? [String: Any] else {
            throw JSONConfigStoreReadError.notADictionary
        }
        return root
    }

    private func writeRoot(_ root: [String: Any], to writeURL: URL) throws {
        let parent = writeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: writeURL, options: [.atomic])
    }

    private func snapshot(from root: [String: Any]) -> Snapshot {
        let video = (root["terminal"] as? [String: Any])?["videoBackground"] as? [String: Any]
        let enabled = VideoBackgroundSettings.decodeBoolean(video?["enabled"])
        let source = video?["source"] as? String
        let queue = video?["queue"] as? [String]
        let muted = VideoBackgroundSettings.decodeBoolean(video?["muted"])
        let quality = (video?["quality"] as? String).map { VideoBackgroundSettings().normalizedQuality($0) }
        let volume: Double? = (video?["volume"] as? NSNumber).flatMap { (value: NSNumber) -> Double? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            return number.isFinite ? VideoBackgroundSettings().normalizedVolume(number) : nil
        }
        let dimOpacity: Double? = (video?["dimOpacity"] as? NSNumber).flatMap { (value: NSNumber) -> Double? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            return number.isFinite ? VideoBackgroundSettings().normalizedDimOpacity(number) : nil
        }
        return Snapshot(
            enabled: enabled,
            source: source,
            queue: queue.map { VideoBackgroundSettings().normalizedQueue($0) },
            muted: muted,
            quality: quality,
            volume: volume,
            dimOpacity: dimOpacity
        )
    }

    private static func resolvedURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Serializes synchronous config transactions across editor instances and
    /// processes. BSD `flock` is used at this file-I/O seam because an actor
    /// cannot protect independent synchronous CLI processes; the critical
    /// section never suspends and the kernel releases the lock on a crash.
    private func withExclusiveFileLock<T>(_ operation: (URL) throws -> T) throws -> T {
        // Use the canonical target for the lock identity. Callers may open the
        // same config through either `cmux.json` or its resolved target path;
        // both must acquire the same sidecar lock. A symlink can change while
        // a descriptor waits, so validate the target after acquisition and
        // retry against the new identity before touching any file.
        for _ in 0..<4 {
            let lockIdentity = Self.resolvedURL(for: fileURL).standardizedFileURL
            let directory = lockIdentity.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lockURL = directory.appendingPathComponent(
                ".\(lockIdentity.lastPathComponent).video-background.lock",
                isDirectory: false
            )
            let descriptor = lockURL.path.withCString {
                Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                defer { _ = Darwin.close(descriptor) }
                while flock(descriptor, LOCK_EX) != 0 {
                    guard errno == EINTR else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
                defer { _ = flock(descriptor, LOCK_UN) }
                let targetURL = Self.resolvedURL(for: fileURL).standardizedFileURL
                guard targetURL == lockIdentity else { continue }
                return try operation(targetURL)
            }
        }
        throw POSIXError(.EAGAIN)
    }
}
