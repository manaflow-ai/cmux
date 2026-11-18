internal import CCmuxLayoutReducerFFI
public import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation
import os

/// The daemon's launch snapshot (`launch-snapshot-v1`): the last settled
/// `list-workspaces` tree with its personal state and this app's window
/// records, which cmux-tui keeps in a read-only file next to its session registry. The app reads it
/// before it connects to draw the last known layout at once, then replaces
/// it with the live tree after the handshake. It is a cache, never a source
/// of truth: nothing is written back from it, and a missing or unreadable
/// file only means the launch shows the connecting state as before.
///
/// The file grows with the session (3.3 MB at 826 workspaces), so the app reads and decodes it off the main
/// thread, from `main` while AppKit starts (``readAtLaunch(work:build:)``); the main thread only applies the result.
public struct LaunchSnapshot: Sendable {
    /// The tree, with `personal` from the file (`list-personal`) so the
    /// provisional sidebar filters and groups as the live one will.
    public var tree: DaemonTree
    /// The window records (`WindowStateStore`'s document), when saved.
    public var windows: WindowStateDocument?
    /// The sidebar document (`sidebar.get`'s JSON) when the daemon saved it: the pinned band draws from it
    /// before the handshake. Nil from an older daemon or one without `sidebar-doc-v1`.
    public var sidebarDoc: Data?
    public var session: String
    public var writtenAtMs: UInt64?
    /// The registry id (session) this home's app last saw live, from its last handshake
    /// (``LaunchSnapshotLocation/knownRegistry(session:)``), read with the file: before the daemon answers, a tree
    /// with another id is another session's snapshot and is never drawn (cmuxterm-hq#12660). Nil before one was recorded.
    public var knownRegistryID: String?

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
        let sidebarDoc = file.sidebarDoc.flatMap { $0 == .null ? nil : try? JSONEncoder().encode($0) }
        return LaunchSnapshot(tree: tree, windows: windows, sidebarDoc: sidebarDoc, session: file.session, writtenAtMs: file.writtenAtMs,
                              knownRegistryID: nil) // `saved` fills it from this home's record
    }

    /// The snapshot the last run of `session` left, read and decoded on the calling thread; nil when there is
    /// none or it cannot be used (logged: the launch then shows the connecting state).
    ///
    /// The path comes from the last handshake (`location`), else from the daemon's state directory
    /// (`stateDirectory`, a tagged build's), so cleared defaults do not lose the snapshot. The read of the file
    /// is a checked blocking call (the search of the state directory is not), so the blocking detector reports
    /// this on the main thread: the app runs it on `BackgroundWork`'s files lane
    /// (``readAtLaunch(work:build:)``) and hands `DaemonService.start` the result.
    public static func saved(session: String, stateDirectory: URL?,
                             location: LaunchSnapshotLocation = LaunchSnapshotLocation()) -> LaunchSnapshot? {
        guard let path = location.path(session: session) ?? LaunchSnapshotLocation.find(session: session, in: stateDirectory) else { return nil }
        do {
            var snapshot = try load(path: path, session: session)
            snapshot.knownRegistryID = location.knownRegistry(session: session)
            if let verdict = snapshot.verdictBeforeConnect(), verdict != "current" {
                throw Skip.otherSession("registry \(snapshot.tree.registryID ?? "none") (\(verdict)), this home's is \(snapshot.knownRegistryID ?? "none")")
            }
            return snapshot
        } catch {
            logger.error("launch snapshot skipped: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The snapshot's standing before the daemon answers (cmux-window-rules `launch::verdict`, served as
    /// `window_launch_snapshot_verdict`, cmuxterm-hq#12660): its tree's registry id against the one this home's last
    /// handshake recorded (``knownRegistryID``), no workspaces. `otherSession` for another session's snapshot, so
    /// the launch never draws its windows, not even until the live tree comes; `current` for this home's own, drawn
    /// as before. Nil when the FFI does not answer (the snapshot is drawn, as before). Workspaces the daemon lost
    /// are known only from its answer: `WindowManager.restore` asks again then.
    func verdictBeforeConnect() -> String? {
        struct Facts: Encodable { var snapshotSession: String?, liveSession: String?, listed: [String] = [], live: [String] = [] }
        struct Reply: Decodable { var verdict: String }
        return Self.rule("window_launch_snapshot_verdict", Facts(snapshotSession: tree.registryID, liveSession: knownRegistryID),
                         as: Reply.self)?.verdict
    }

    /// One launch op of the app FFI's window rules (cmux-window-rules `launch`); nil when it does not answer (an FFI
    /// pinned before the op).
    static func rule<Request: Encodable, Reply: Decodable>(_ op: String, _ request: Request, as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var output = [UInt8](repeating: 0, count: 1024), length = 0
        let code: Int32 = data.withUnsafeBytes { request in
            op.withCString { operation in
                output.withUnsafeMutableBytes { buffer in
                    cmux_layout_reducer_json(request.bindMemory(to: UInt8.self).baseAddress, data.count, operation,
                                             buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &length)
                }
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, length <= output.count else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(length)))
    }

    /// ``saved(session:stateDirectory:location:)`` for the app daemon's session of `build`
    /// (``DaemonLauncher/appNames(build:applicationSupport:log:)``), put on `work`'s files lane before this
    /// returns, from `main`: the read and the decode overlap AppKit's start, and the launch awaits the task (no
    /// thread waits) before `DaemonService.start`. The launch mark `daemon.launch_snapshot_read` says when the
    /// read ended.
    ///
    /// ```swift
    /// let snapshot = LaunchSnapshot.readAtLaunch(work: work, build: build)   // in `main`, before the other launch reads
    /// daemon.start(..., launchSnapshot: await snapshot.value)
    /// ```
    public static func readAtLaunch(work: BackgroundWork, build: BuildIdentity) -> Task<LaunchSnapshot?, Never> {
        readAtLaunch(work: work) { DaemonLauncher.appNames(build: build) }
    }

    /// ``readAtLaunch(work:build:)`` for the session `names` gives (called on the lane thread).
    ///
    /// The item is posted here, in the caller's turn, so it is first on the lane's slot: the launch window waits
    /// for this read, and `main` posts the pages' and the terminals' saved frames (megabytes, decoded) on the
    /// same slot right after it. A read that entered the lane only when its task first ran queued behind them.
    static func readAtLaunch(work: BackgroundWork, location: LaunchSnapshotLocation = LaunchSnapshotLocation(),
                             names: @escaping @Sendable () -> (session: String, stateDirectory: URL?)) -> Task<LaunchSnapshot?, Never> {
        let (results, result) = AsyncStream<LaunchSnapshot?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // `.blockShutdown`: the launch awaits the result, so a shutdown of `work` must not skip the item.
        work.post(.userBlocking, mayBlock: .files, shutdown: .blockShutdown) {
            let daemon = names()
            result.yield(Self.saved(session: daemon.session, stateDirectory: daemon.stateDirectory, location: location))
            result.finish()
            DaemonLaunchTimings.shared.mark("daemon.launch_snapshot_read")
        }
        // task-owner: AppDelegate.launchSnapshot; awaited once by its launch task, which then drops it.
        return Task.detached(priority: .userInitiated) {
            for await snapshot in results { return snapshot }
            return nil
        }
    }

    // The subsystem and category of `DaemonService.logger`, which wrote this line before the read moved here.
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.daemon")

    /// Reads the snapshot at `path` (from `LaunchSnapshotLocation`): a blocking read, checked.
    static func load(path: String, session: String) throws(Skip) -> LaunchSnapshot {
        let url = URL(fileURLWithPath: path)
        let size: Int
        do { size = try url.blockingResourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 } catch { throw .unreadable(String(describing: error)) }
        guard size <= maximumBytes else { throw .tooLarge(size) }
        let data: Data
        do { data = try Data(blockingContentsOf: url) } catch { throw .unreadable(String(describing: error)) }
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
        /// Absent in a file from an older daemon.
        var sidebarDoc: JSONValue?

        enum CodingKeys: String, CodingKey {
            case session, tree, personal
            case sidebarDoc = "sidebar_doc"
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
///
/// The defaults are the account's whatever the home: two copies of a build with one bundle id and a home each (an
/// A/B's two sides) share them, so the path can name the other home's snapshot. The registry id the last handshake
/// reported is kept in this home's own folder (``knownRegistry(session:)``), so the launch tells that snapshot from
/// its own before the daemon answers.
public struct LaunchSnapshotLocation: Sendable {
    let defaults: @Sendable () -> UserDefaults
    /// This home's `Library/Application Support` (`NextSupport.applicationSupport`): the known registry id is kept in
    /// its `cmux-next` folder.
    let applicationSupport: @Sendable () -> URL

    public init(defaults: @escaping @Sendable () -> UserDefaults = { .standard },
                applicationSupport: @escaping @Sendable () -> URL = { NextSupport.applicationSupportDirectory() }) {
        self.defaults = defaults
        self.applicationSupport = applicationSupport
    }

    /// `<Application Support>/cmux-next/launch-snapshot-registry.<session>`: the registry id the last handshake of
    /// `session` reported, the id alone in UTF-8. Read only by cmux-window-rules `launch::current_registry_id`, which
    /// the launch shell's stage 0 reads too.
    func registryFile(session: String) -> URL {
        NextSupport(applicationSupport: applicationSupport()).folder
            .appendingPathComponent("launch-snapshot-registry." + session, isDirectory: false)
    }

    /// The registry id this home's app last saw live for `session` (`window_launch_current_registry`, the one reader
    /// of ``registryFile(session:)``); nil before one was recorded or when the FFI does not answer. A blocking read
    /// of a few bytes, on the launch read's files lane (``LaunchSnapshot/saved(session:stateDirectory:location:)``).
    public func knownRegistry(session: String) -> String? {
        struct Request: Encodable { var appSupport: String, session: String }
        struct Reply: Decodable { var registryId: String? }
        return LaunchSnapshot.rule("window_launch_current_registry", Request(appSupport: applicationSupport().path, session: session),
                                   as: Reply.self)?.registryId
    }

    /// Records the registry id a handshake of `session` reported. A blocking write: off the main thread.
    public func recordRegistry(_ id: String, session: String) {
        guard !id.isEmpty, id.utf8.count <= 256 else { return }
        let file = registryFile(session: session)
        try? FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(id.utf8).blockingWrite(to: file, options: .atomic)
    }

    static func key(session: String) -> String { "cmuxNext.launchSnapshotPath." + session }

    public func path(session: String) -> String? {
        defaults().string(forKey: Self.key(session: session))
    }

    /// The newest launch snapshot of `session` in a daemon state directory
    /// (`CMUX_TUI_STATE_DIR`), where cmux-tui keeps each registry in
    /// `<session>-<id>/`: the path when the defaults lost it. Nil without a
    /// directory or a snapshot.
    public static func find(session: String, in stateDirectory: URL?, files: FileManager = .default) -> String? {
        guard let stateDirectory,
              let entries = try? files.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil) else { return nil }
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
