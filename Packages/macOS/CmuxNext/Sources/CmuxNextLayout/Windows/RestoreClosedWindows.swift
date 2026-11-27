/// The windows the person closed while the launch's restore ran (cx-ghagp), which the restore must
/// not open again. The restore puts back the saved registry, where they are open; `keepClosed`
/// closes them in the same registry step, so no sync ever opens (and presents) one in between.
///
/// The restore's own workspaces can be reported after it ended: its first workspace's create
/// replies before the store applies the event that lists it. Had the memory of the closed launch
/// window ended with the restore, that late report found no window and opened a new one, showing
/// the window the person closed. So the launch window is remembered, as the closed window those
/// workspaces go to, until each is in a window or is known gone (`settle`).
public struct RestoreClosedWindows: Equatable, Sendable {
    /// The windows the person closed before the restore finished.
    public private(set) var windows: Set<String> = []
    /// The launch window the person closed before the restore finished: what it would have shown
    /// is registered under this id, closed (reconcile's fallback window).
    public private(set) var launchWindowID: String?
    /// The workspaces the restore asked for that its store did not list when it ended.
    public private(set) var awaited: Set<String> = []
    /// The store's event sequence taken after their creates replied: once the store applied this
    /// far, one it does not list is gone.
    public private(set) var barrier: UInt64 = 0

    public init() {}

    /// The person closed window `id` during the restore; `launch` when it is the launch window.
    public mutating func closed(_ id: String, launch: Bool = false) {
        windows.insert(id)
        if launch { launchWindowID = id }
    }

    /// The person opened window `id` again on purpose: the restore keeps it open.
    public mutating func reopened(_ id: String) {
        windows.remove(id)
    }

    /// The restore asked for `ids`, which its store did not list after the creates replied.
    public mutating func awaiting(_ ids: Set<String>, barrier: UInt64) {
        awaited = ids
        self.barrier = barrier
    }

    /// Closes every remembered window `registry` has open.
    public func keepClosed(_ registry: inout WindowRegistry) {
        for id in windows where registry.window(id)?.isOpen == true { registry.setRestored(id, open: false) }
    }

    /// The restore ended: only the closed launch window stays remembered, and only while a
    /// workspace the restore asked for can still arrive.
    public mutating func restoreEnded(in registry: WindowRegistry, applied: UInt64, listed: (String) -> Bool) {
        guard let launch = launchWindowID, windows.contains(launch), !awaited.isEmpty else { return self = .init() }
        windows = [launch]
        settle(in: registry, applied: applied, listed: listed)
    }

    /// After the restore, drops each awaited workspace a window of `registry` holds, and each the
    /// store applied past `barrier` without listing (`listed`); with none left, everything is
    /// forgotten. Reconcile runs it before it picks its fallback window, so a memory that has
    /// nothing to wait for takes no other workspace, and after, so it ends with the placement.
    public mutating func settle(in registry: WindowRegistry, applied: UInt64, listed: (String) -> Bool) {
        guard !awaited.isEmpty else { return }
        awaited = awaited.filter { registry.owner(of: $0) == nil && (applied < barrier || listed($0)) }
        if awaited.isEmpty { self = .init() }
    }
}
