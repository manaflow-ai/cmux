import Foundation

/// Decides whether Kill Process may end a process. Pure apart from the
/// injected ``ProcessLineage``.
///
/// Allowed: a running local process that the app or a daemon started (one
/// of them is an ancestor), whose executable or an ancestor's lies inside
/// the app bundle (Chromium helpers, terminal hosts), or that the last
/// Task Manager sample listed (WebKit WebContent processes, started by
/// launchd for the app). Never the app, a daemon, pid 1 or a remote process.
public struct TaskManagerKillPolicy {
    public var appPID: Int32
    public var daemonPIDs: Set<Int32>
    /// The app bundle path; nil skips the bundle rule.
    public var bundlePath: String?
    /// Local pids the last sample listed.
    public var listedPIDs: Set<Int32>

    /// Longest parent chain walked; a deeper one is not cmux's.
    static let maximumDepth = 64

    public init(appPID: Int32, daemonPIDs: Set<Int32> = [], bundlePath: String? = nil, listedPIDs: Set<Int32> = []) {
        self.appPID = appPID
        self.daemonPIDs = daemonPIDs
        self.bundlePath = bundlePath
        self.listedPIDs = listedPIDs
    }

    /// The refusal for `key`, or nil when it may be ended.
    public func refusal(for key: ProcessKey, lineage: any ProcessLineage) -> TaskManagerKillRefusal? {
        guard key.host == ProcessKey.localHost else { return .remoteHost }
        guard key.pid > 1 else { return key.pid == 1 ? .notCmuxProcess : .invalid }
        if key.pid == appPID { return .appProcess }
        if daemonPIDs.contains(key.pid) { return .daemonProcess }
        guard var parent = lineage.parent(of: key.pid) else { return .notRunning }
        if listedPIDs.contains(key.pid) || insideBundle(key.pid, lineage) { return nil }
        let roots = daemonPIDs.union([appPID])
        for _ in 0..<Self.maximumDepth where parent > 1 {
            if roots.contains(parent) || insideBundle(parent, lineage) { return nil }
            guard let next = lineage.parent(of: parent) else { break }
            parent = next
        }
        return .notCmuxProcess
    }

    private func insideBundle(_ pid: Int32, _ lineage: any ProcessLineage) -> Bool {
        guard let bundlePath, !bundlePath.isEmpty, let path = lineage.executablePath(of: pid) else { return false }
        let root = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return path.hasPrefix(root)
    }
}
