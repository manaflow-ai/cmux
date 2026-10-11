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

    /// Records what the handshake reported (nil forgets it).
    public func record(_ path: String?, session: String) {
        let key = Self.key(session: session)
        guard defaults().string(forKey: key) != path else { return }
        defaults().set(path, forKey: key)
    }
}
