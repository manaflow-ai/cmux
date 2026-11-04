public import Foundation

/// What the app was doing shortly before it ended, kept in the run marker so
/// the next launch's crash report can say it (``CrashContextRecorder``).
///
/// Counts, kinds and action ids only: never a path, URL, page title, tab
/// title or terminal text.
public nonisolated struct CrashContext: Codable, Equatable, Sendable {
    /// One action run (keyboard, menu, palette, CLI or socket).
    public struct Action: Codable, Equatable, Sendable {
        /// The action id (`workspace.new`).
        public var id: String
        /// How it was invoked (`key`, `pointer`, `cli`).
        public var entrypoint: String
        /// When it started.
        public var at: Date

        /// - Parameters:
        ///   - id: The action id.
        ///   - entrypoint: How it was invoked.
        ///   - at: When it started.
        public init(id: String, entrypoint: String, at: Date) {
            self.id = id
            self.entrypoint = entrypoint
            self.at = at
        }
    }

    /// The most actions a context keeps.
    public static let actionLimit = 12

    /// When this snapshot was taken.
    public var updated: Date
    /// Open app windows.
    public var windows: Int
    /// Workspaces on this Mac's session.
    public var workspaces: Int
    /// Terminal tabs (local and remote).
    public var terminalTabs: Int
    /// Browser tabs.
    public var browserTabs: Int
    /// Every other tab (conversations, files, apps).
    public var otherTabs: Int
    /// The focused pane's tab kind (`pty`, `browser`, `conversation`), nil with no focused tab.
    public var focusedPane: String?
    /// The Chromium engine's start state (`idle`, `ready`), nil when unknown.
    public var browserEngine: String?
    /// Chromium helper or renderer failures this run.
    public var browserFailures: Int
    /// The app process's physical footprint, in megabytes.
    public var footprintMegabytes: Int
    /// The newest action runs, newest first (at most ``actionLimit``).
    public var actions: [Action]

    /// A snapshot.
    ///
    /// - Parameters:
    ///   - updated: When it was taken.
    ///   - windows: Open app windows.
    ///   - tabKinds: Every open tab's kind (`pty`, `remote-terminal`, `browser`, any other).
    ///   - workspaces: Workspaces on this Mac's session.
    ///   - focusedPane: The focused tab's kind.
    ///   - browserEngine: The Chromium engine's start state.
    ///   - browserFailures: Chromium helper or renderer failures this run.
    ///   - footprintMegabytes: The app's physical footprint.
    ///   - actions: The newest action runs, newest first; only the first ``actionLimit`` are kept.
    public init(updated: Date, windows: Int, workspaces: Int, tabKinds: [String], focusedPane: String?,
                browserEngine: String?, browserFailures: Int, footprintMegabytes: Int, actions: [Action]) {
        self.updated = updated
        self.windows = windows
        self.workspaces = workspaces
        terminalTabs = tabKinds.count { $0 == "pty" || $0 == "remote-terminal" }
        browserTabs = tabKinds.count { $0 == "browser" }
        otherTabs = tabKinds.count - terminalTabs - browserTabs
        self.focusedPane = focusedPane
        self.browserEngine = browserEngine
        self.browserFailures = browserFailures
        self.footprintMegabytes = footprintMegabytes
        self.actions = Array(actions.prefix(Self.actionLimit))
    }

    /// One breadcrumb per run, newest first, its start moved from the uptime clock to the wall clock.
    ///
    /// - Parameters:
    ///   - runs: The runs, newest first: id, entrypoint and `CLOCK_UPTIME_RAW` start in nanoseconds.
    ///   - now: The wall clock when `nowUptimeNanos` was read.
    ///   - nowUptimeNanos: `CLOCK_UPTIME_RAW` now, in nanoseconds.
    /// - Returns: At most ``actionLimit`` actions.
    public static func actions(_ runs: [(id: String, entrypoint: String, startUptimeNanos: UInt64)], now: Date,
                               nowUptimeNanos: UInt64) -> [Action] {
        runs.prefix(actionLimit).map { run in
            let ago = nowUptimeNanos > run.startUptimeNanos ? Double(nowUptimeNanos - run.startUptimeNanos) / 1e9 : 0
            return Action(id: run.id, entrypoint: run.entrypoint, at: now.addingTimeInterval(-ago))
        }
    }

    /// `phys_footprint` (Activity Monitor's "Memory") of this process, in megabytes; 0 when unknown.
    public static func footprintMegabytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }
}
