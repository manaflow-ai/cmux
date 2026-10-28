import CmuxNextCompat
public import Foundation

/// The daemon's launch snapshot (`launch-snapshot-v1`): the last settled
/// `list-workspaces` tree with its personal state and this app's window
/// records, which cmux-tui keeps in a read-only file next to its session registry. The app reads it
/// before it connects to draw the last known layout at once, then replaces
/// it with the live tree after the handshake. It is a cache, never a source
/// of truth: nothing is written back from it, and a missing or unreadable
/// file only means the launch shows the connecting state as before.
public struct LaunchSnapshot: Sendable {
    /// The tree, with `personal` from the file (`list-personal`) so the
    /// provisional sidebar filters and groups as the live one will.
    public var tree: DaemonTree
    /// The window records (`WindowStateStore`'s document), when saved.
    public var windows: WindowStateDocument?
    public var session: String
    public var writtenAtMs: UInt64?

    /// A snapshot larger than this is not read (the daemon caps it at 8 MiB).
    public static let maximumBytes = 8 * 1024 * 1024
    static let schemaVersion = 1

    /// Why a snapshot file was not used (logged: a skipped snapshot shows the connecting state).
    public enum Skip: Error, CustomStringConvertible {
        case unreadable(String), tooLarge(Int), undecodable(String), otherSchema(Int), otherSession(String)

        public var description: String {
            switch self {
            case .unreadable(let reason): "unreadable: \(reason)"
            case .tooLarge(let bytes): "too large: \(bytes) bytes"
            case .undecodable(let reason): "undecodable: \(reason)"
            case .otherSchema(let version): "schema \(version)"
            case .otherSession(let session): "session \(session)"
            }
        }
    }

    /// Decodes a snapshot file's bytes; nil for another schema or session.
    public static func decode(_ data: Data, session: String,
                              frontend: String = DaemonConnection.origin,
                              windowsSubject: String = WindowStateStore.defaultSubject) -> LaunchSnapshot? {
        try? read(data, session: session, frontend: frontend, windowsSubject: windowsSubject)
    }

    /// `decode`, throwing why the bytes were not used.
    public static func read(_ data: Data, session: String,
                            frontend: String = DaemonConnection.origin,
                            windowsSubject: String = WindowStateStore.defaultSubject) throws(Skip) -> LaunchSnapshot {
        guard data.count <= maximumBytes else { throw .tooLarge(data.count) }
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) } catch { throw .undecodable(String(describing: error)) }
        guard file.schemaVersion == schemaVersion else { throw .otherSchema(file.schemaVersion) }
        guard file.session == session else { throw .otherSession(file.session) }
        let record = file.frontendProjections?.first { projection in
            projection.frontend == frontend && projection.scope == ProjectionScope.personal.rawValue
                && projection.subjectKey == windowsSubject
        }
        let windows = record.flatMap { record -> WindowStateDocument? in
            guard record.schemaVersion == WindowStateDocument.schemaVersion, record.projection != .null else { return nil }
            return try? WindowStateDocument(jsonValue: record.projection)
        }
        var tree = file.tree
        tree.personal = file.personal
        return LaunchSnapshot(tree: tree, windows: windows, session: file.session, writtenAtMs: file.writtenAtMs)
    }

    /// Reads the snapshot at `path` (from `LaunchSnapshotLocation`).
    public static func load(path: String, session: String) throws(Skip) -> LaunchSnapshot {
        let url = URL(fileURLWithPath: path)
        let size: Int
        do { size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 } catch { throw .unreadable(String(describing: error)) }
        guard size <= maximumBytes else { throw .tooLarge(size) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw .unreadable(String(describing: error)) }
        return try read(data, session: session)
    }

    /// What looking for a session's snapshot found (``find(session:stateDirectory:location:)``).
    public enum Found: Sendable {
        /// No path remembered and none in the state directory.
        case missing
        /// A file that could not be used, and why.
        case skipped(Skip)
        case snapshot(LaunchSnapshot)

        /// The snapshot, when one was read.
        public var snapshot: LaunchSnapshot? {
            if case .snapshot(let snapshot) = self { snapshot } else { nil }
        }
    }

    /// Finds `session`'s snapshot (the path the last handshake reported, else the newest in the daemon's state
    /// directory, so cleared defaults do not lose it) and reads it. It lists a directory and reads and decodes up to
    /// ``maximumBytes`` of JSON: call it off the main thread (the app: on the files lane from `main`,
    /// ``LaunchSnapshotPrefetch``).
    public static func find(session: String, stateDirectory: URL?,
                            location: LaunchSnapshotLocation = LaunchSnapshotLocation()) -> Found {
        guard let path = location.path(session: session) ?? LaunchSnapshotLocation.find(session: session, in: stateDirectory) else {
            return .missing
        }
        do { return try .snapshot(load(path: path, session: session)) } catch { return .skipped(error) }
    }

    private struct File: Decodable {
        var schemaVersion: Int
        var session: String
        var writtenAtMs: UInt64?
        var tree: DaemonTree
        /// Absent in a file from an older daemon.
        var personal: PersonalState?
        var frontendProjections: [FrontendProjection]?

        enum CodingKeys: String, CodingKey {
            case session, tree, personal
            case schemaVersion = "schema_version"
            case writtenAtMs = "written_at_ms"
            case frontendProjections = "frontend_projections"
        }
    }
}

/// Where the daemon of a session keeps its launch snapshot, remembered from
/// the last handshake (`identify.launch_snapshot_path`), so the next launch
/// can read it before connecting. Stored per session name in the app's
/// defaults; only a path, never the contents.
public struct LaunchSnapshotLocation: Sendable {
    let defaults: @Sendable () -> UserDefaults

    public init(defaults: @escaping @Sendable () -> UserDefaults = { .standard }) {
        self.defaults = defaults
    }

    static func key(session: String) -> String { "cmuxNext.launchSnapshotPath." + session }

    public func path(session: String) -> String? {
        defaults().string(forKey: Self.key(session: session))
    }

    /// The newest launch snapshot of `session` in a daemon state directory
    /// (`CMUX_TUI_STATE_DIR`), where cmux-tui keeps each registry in
    /// `<session>-<id>/`: the path when the defaults lost it. Nil without a
    /// directory or a snapshot.
    public static func find(session: String, in stateDirectory: URL?) -> String? {
        guard let stateDirectory,
              let entries = try? FileManager.checked.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil) else { return nil }
        // `<session>-<id>` with one id part, so `cmux-app-a` never takes `cmux-app-a-b`'s registry.
        let ours = entries.filter { entry in
            let name = entry.lastPathComponent
            return name.hasPrefix(session + "-") && !name.dropFirst(session.count + 1).contains("-")
        }
        let candidates = ours.compactMap { directory -> (String, Date)? in
            let file = directory.appendingPathComponent(fileName)
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (file.path, modified)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    /// The daemon's snapshot file name (`LAUNCH_SNAPSHOT_FILE`).
    static let fileName = "launch-snapshot.json"

    /// Records what the handshake reported (nil forgets it).
    public func record(_ path: String?, session: String) {
        let key = Self.key(session: session)
        guard defaults().string(forKey: key) != path else { return }
        defaults().set(path, forKey: key)
    }
}

/// The launch snapshot's read, begun in `main` on the files lane before AppKit starts (the app: a `LaunchRead`), which
/// `DaemonService.start` takes over: it applies the snapshot in its own turn when the read has ended, else on the
/// read's end, so the main thread never reads or decodes the file (p08-startup-074).
public struct LaunchSnapshotPrefetch: Sendable {
    /// The session whose snapshot it reads; a start for another session reads its own.
    public let session: String
    private let ended: @Sendable () -> LaunchSnapshot.Found?
    private let finished: @Sendable () async -> LaunchSnapshot.Found

    /// - Parameters:
    ///   - session: The session whose snapshot it reads.
    ///   - ended: What the read found, from any thread and never waiting; nil while it runs.
    ///   - finished: What the read found, once it has ended (the caller suspends; no thread waits).
    public init(session: String, ended: @escaping @Sendable () -> LaunchSnapshot.Found?,
                finished: @escaping @Sendable () async -> LaunchSnapshot.Found) {
        (self.session, self.ended, self.finished) = (session, ended, finished)
    }

    /// What the read found, never waiting; nil while it runs.
    public var found: LaunchSnapshot.Found? { ended() }

    /// What the read found, once it has ended.
    public func result() async -> LaunchSnapshot.Found { await finished() }
}
