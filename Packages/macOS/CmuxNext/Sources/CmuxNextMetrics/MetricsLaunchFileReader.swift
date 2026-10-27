import CmuxNextCompat
public import CmuxNextTrace
import Darwin
public import Foundation

/// One earlier launch's metrics file as ``MetricsLaunchFileReader`` reads it: the samples that launch had not
/// uploaded, under that launch's own profile.
public struct MetricsLaunchContents: Sendable, Equatable, Identifiable {
    /// The source launch, from the file's header: its boot session, start wall clock, role and pid. A later launch
    /// that gets the same pid (after a wrap or a reboot) has another start time and usually another boot session.
    public let id: String
    /// The samples the launch had not uploaded (each bucket minus its logged shadow), with its profile.
    public let delta: MetricsDelta

    /// The source launch's profile (version, build, channel, OS, hardware class, boot session).
    public var profile: MetricsProfile { delta.profile }

    /// Contents from their parts.
    public init(id: String, delta: MetricsDelta) {
        self.id = id
        self.delta = delta
    }
}

/// Reads the metrics files ``MetricsStore`` writes (task 052's layout) for ``MetricsLaunchFold``: maps a file
/// read-only, validates it with ``MetricsImage/init(validating:byteCount:)`` and copies out its profile and delta.
///
/// Chrome's model: `FileMetricsProvider` maps each file the previous runs left and reads it through a
/// `PersistentHistogramAllocator` over that mapping, with the system profile the file carries
/// (components/metrics/file_metrics_provider.cc, components/metrics/persistent_system_profile.cc).
///
/// Every call reads files: call it off the main thread (BackgroundWork `.files`), as ``MetricsLaunchFold`` is.
///
/// ```swift
/// let reader = MetricsLaunchFileReader(role: .app)
/// let fold = MetricsLaunchFold(directory: folder, current: thisLaunchFile, reader: reader)
/// ```
public struct MetricsLaunchFileReader: MetricsLaunchReading {
    /// The process kind whose files are read.
    public let role: TraceRuntime.Role

    /// A reader of `role`'s launch files.
    public init(role: TraceRuntime.Role) {
        self.role = role
    }

    /// Whether `file` is ``MetricsStore/fileName(role:pid:)`` of this role for some pid: not the role's spare
    /// (``MetricsStore/spareName(role:)``), not a spare being built (`*.tmp`), not another role's file.
    public func isLaunchFile(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        guard name.hasSuffix(".bin"), let dash = name.lastIndex(of: "-"),
              let pid = UInt32(name[name.index(after: dash)...].dropLast(4)) else { return false }
        return name == MetricsStore.fileName(role: role, pid: pid)
    }

    /// The profile, unsent samples and source launch id of `file`. Throws
    /// ``MetricsLaunchFoldError/unreadable(_:)`` when the file cannot be mapped, is not a version 1 metrics image
    /// (a launch killed while it renamed the spare and wrote the header) or holds another role's header.
    public func read(_ file: URL) throws(MetricsLaunchFoldError) -> MetricsLaunchContents {
        assertBlockingAllowed(.fileIO)
        let path = file.path(percentEncoded: false)
        let contents: MetricsLaunchContents? = blockingCall(.fileIO) {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, let byteCount = Int(exactly: info.st_size), byteCount > 0 else { return nil }
            let mapping = mmap(nil, byteCount, PROT_READ, MAP_SHARED, descriptor, 0)
            guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
            defer { munmap(mapping, byteCount) }
            guard let image = MetricsImage(validating: mapping, byteCount: byteCount), image.role == role.rawValue else {
                return nil
            }
            return MetricsLaunchContents(id: image.sourceLaunchID, delta: image.delta())
        }
        guard let contents else { throw MetricsLaunchFoldError.unreadable(file) }
        return contents
    }
}

extension MetricsImage {
    /// The header's start wall clock, ns since 1970 (``MetricsStore`` "File layout", offset 40).
    var startUnixNanos: UInt64 {
        UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 40, as: UInt64.self))
    }

    /// `<role>-<pid>-<start wall clock ns>-<boot session hex>`: the launch that wrote this image. The boot session
    /// part is left out when the header has none.
    var sourceLaunchID: String {
        let launch = "\(role)-\(pid)-\(startUnixNanos)"
        let boot = profile.bootSessionUUID.map { String(format: "%02x", $0) }.joined()
        return boot.isEmpty ? launch : launch + "-" + boot
    }
}
