import Darwin
public import Foundation

/// Owns the discovery marker files for one cmux build variant.
///
/// The store is constructed at the composition root with the running bundle
/// identity, environment, and file manager. Callers that clear state must hold
/// the corresponding socket-path lock for the entire operation.
// Safety: all stored dependencies are immutable after initialization and every
// method performs independent filesystem operations without shared in-memory state.
public final class SocketPathMarkerStore: @unchecked Sendable {
    /// Maximum marker payload accepted from disk.
    public static let maximumMarkerBytes = 4_096

    private let bundleIdentifier: String?
    private let environment: [String: String]
    private let fileManager: FileManager
    private let stateDirectory: URL
    private let legacyDirectory: URL?
    private let tmpMarkerPath: String

    /// Creates a marker store for one process identity.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The running app's bundle identifier.
    ///   - environment: The process environment used to derive variant markers.
    ///   - stateDirectory: Current unprotected cmux state directory.
    ///   - legacyDirectory: Optional legacy Application Support directory.
    ///   - tmpMarkerPath: Variant-specific legacy marker under `/tmp`.
    ///   - fileManager: Filesystem dependency used for marker writes and removal.
    public init(
        bundleIdentifier: String?,
        environment: [String: String],
        stateDirectory: URL,
        legacyDirectory: URL?,
        tmpMarkerPath: String,
        fileManager: FileManager = .default
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.environment = environment
        self.stateDirectory = stateDirectory
        self.legacyDirectory = legacyDirectory
        self.tmpMarkerPath = tmpMarkerPath
        self.fileManager = fileManager
    }

    /// Records a live socket path in the current variant's marker files.
    ///
    /// - Parameter path: Absolute socket path to publish.
    public func record(_ path: String) {
        let payload = Data((path + "\n").utf8)
        for filePath in markerPaths() {
            writeMarker(payload, to: filePath)
        }
    }

    /// Removes markers that still point at `path`.
    ///
    /// Each read is bounded and the file identity/payload are checked again
    /// immediately before removal. A caller must hold the socket-path lock while
    /// invoking this method so a replacement listener cannot publish concurrently.
    ///
    /// - Parameter path: Socket path owned by the stopped listener.
    public func clearIfMatching(_ path: String) {
        for filePath in markerPaths() {
            guard let before = regularMarkerIdentity(at: filePath),
                  let contents = boundedMarkerContents(at: filePath),
                  SocketControlSettings.pathsMatch(contents, path)
            else {
                continue
            }

            guard let after = regularMarkerIdentity(at: filePath),
                  before.device == after.device,
                  before.inode == after.inode,
                  let currentContents = boundedMarkerContents(at: filePath),
                  SocketControlSettings.pathsMatch(currentContents, path)
            else {
                continue
            }
            try? fileManager.removeItem(atPath: filePath)
        }
    }

    /// Returns the current and legacy marker paths in deterministic order.
    public func markerPaths() -> [String] {
        let variant = SocketPathMarkerFiles.variant(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            baseDebugBundleIdentifier: SocketControlSettings.baseDebugBundleIdentifier
        )
        let paths = [
            SocketPathMarkerFiles.markerFileURL(
                fileName: variant.markerFileName,
                directory: stateDirectory
            )?.path,
            SocketPathMarkerFiles.markerFileURL(
                fileName: variant.markerFileName,
                directory: legacyDirectory
            )?.path,
            tmpMarkerPath,
        ].compactMap(\.self)
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private struct MarkerIdentity {
        let device: UInt64
        let inode: UInt64
    }

    private func regularMarkerIdentity(at path: String) -> MarkerIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= off_t(Self.maximumMarkerBytes)
        else {
            return nil
        }
        return MarkerIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private func boundedMarkerContents(at path: String) -> String? {
        guard regularMarkerIdentity(at: path) != nil else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumMarkerBytes + 1),
              data.count <= Self.maximumMarkerBytes,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeMarker(_ payload: Data, to path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let parentURL = url.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? payload.write(to: url, options: .atomic)
    }
}
