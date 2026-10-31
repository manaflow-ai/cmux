public import CmuxNextWakeups

/// This Mac's install id (``CloudPaths/loadOrCreateDeviceID()``), read once per launch on the app's files
/// lane and kept: it never changes once written, and every window record save reads it, so a pane focus
/// move does no file I/O (speed-of-sound-DESIGN.md 3.2).
///
/// The first read creates the Cloud folders and the id file on a new install (blocking probe 2026-10-24:
/// ``CloudPaths`` `prepare()`, 2.3 ms on the main thread at launch). ``preload()`` starts that read off the
/// main thread when Cloud starts; async callers ``load()`` it. ``loadNow()`` is for the synchronous callers:
/// it returns the kept id, and reads on the calling thread only before the launch read ends (the file then
/// has one id: the first id written wins).
///
/// ```swift
/// let deviceID = CloudDeviceID(paths: paths, work: work)
/// deviceID.preload()                       // Cloud start
/// let install = try await deviceID.load()  // a window record save
/// ```
@MainActor
public final class CloudDeviceID {
    private let paths: CloudPaths
    private let work: BackgroundWork
    /// The id, once a read returned it; nil before.
    public private(set) var cached: String?
    /// The read in flight (or done); nil before the first read and after a failed one.
    private var loading: Task<String, any Error>?

    /// Makes the store; it reads nothing yet.
    ///
    /// - Parameters:
    ///   - paths: the install's Cloud folder.
    ///   - work: the app's blocking-work lanes; the read runs on the `.files` lane.
    public init(paths: CloudPaths, work: BackgroundWork) {
        self.paths = paths
        self.work = work
    }

    /// Starts the read off the main thread (Cloud start, at launch); the id is kept when it ends.
    public func preload() {
        guard cached == nil, loading == nil else { return }
        _ = start()
    }

    /// The id, read (or created) on the files lane the first time; concurrent callers share one read.
    ///
    /// - Returns: the id, `mac-<uuid>`.
    /// - Throws: the file error of the read; a later call reads again.
    public func load() async throws -> String {
        if let cached { return cached }
        return try await (loading ?? start()).value
    }

    /// The id for a synchronous caller: the kept one, else a read on this thread (only before the launch
    /// read ends; accepted once, lead 2026-10-25). The read goes through the checked blocking seams
    /// (``CloudPaths/loadOrCreateDeviceID()``), so the main-thread blocking detector names it if it ever
    /// happens on main.
    ///
    /// - Returns: the id, `mac-<uuid>`.
    /// - Throws: the file error of the read.
    public func loadNow() throws -> String {
        if let cached { return cached }
        let id = try paths.loadOrCreateDeviceID()
        cached = id
        return id
    }

    private func start() -> Task<String, any Error> {
        let paths = paths, work = work
        // A window record save waits for it soon after launch: shown state, not a person's click.
        let task = Task(priority: WorkPriority.userVisible.taskPriority) { [weak self] in
            do {
                let id = try await work.run(.userVisible, mayBlock: .files) { try paths.loadOrCreateDeviceID() }
                self?.cached = id
                return id
            } catch {
                self?.loading = nil  // a later call reads again
                throw error
            }
        }
        loading = task
        return task
    }
}
