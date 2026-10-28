/// Numeric launch values kept in the process, each also sent to the startup bench's pipe.
/// One per app, owned by `AppServices`. `debug.startup` (task 008) reads ``values`` through its composition
/// root's `counters:` source, `{ StartupReport.Counters(values: services.launchValues.values) }`;
/// `debug.timings` lists them as `launch_values`.
@MainActor
public final class LaunchValueMarks {
    /// The sidebar's row views built before startup completed (`SidebarModel.LaunchRows.Report.built`).
    public static let sidebarRowsBuilt = "launch.sidebar_rows_built"
    /// The rows the sidebar's clip showed at completion (`SidebarModel.LaunchRows.Report.visible`).
    public static let sidebarRowsVisible = "launch.sidebar_rows_visible"
    /// The main thread's wait for the launch warm-up thread's action catalog build at the registry's read,
    /// in microseconds (`ActionCatalogMainAccess.waitMicroseconds`; target 0).
    public static let actionCatalogMainWait = "launch.action_catalog_main_wait_us"
    /// The main thread's whole time in that read, in microseconds: a build on main counts here, not as a wait.
    public static let actionCatalogMainRead = "launch.action_catalog_main_read_us"

    /// Each value by name, its first record.
    public private(set) var values: [String: Double] = [:]
    private let pipe: (_ name: String, _ value: UInt64) -> Void

    /// - Parameter pipe: Sends a kept value to the startup bench (the app passes `LaunchMarkSink.writeValue`).
    public init(pipe: @escaping (_ name: String, _ value: UInt64) -> Void) {
        self.pipe = pipe
    }

    /// Keeps `name`'s first value and sends it to the pipe, as the bench's pipe reader and
    /// `StartupReport.Counters.record` keep the first; a later value of the same name is dropped.
    public func record(_ name: String, value: UInt64) {
        guard values[name] == nil else { return }
        values[name] = Double(value)
        pipe(name, value)
    }

    /// Keeps the registry's read of the launch's action catalog.
    public func recordActionCatalogMainAccess(waitMicroseconds: UInt64, readMicroseconds: UInt64) {
        record(Self.actionCatalogMainWait, value: waitMicroseconds)
        record(Self.actionCatalogMainRead, value: readMicroseconds)
    }

    /// Keeps what one sidebar built before startup completed (the first window's stay).
    public func recordSidebarLaunchRows(built: Int, visible: Int) {
        record(Self.sidebarRowsBuilt, value: UInt64(max(0, built)))
        record(Self.sidebarRowsVisible, value: UInt64(max(0, visible)))
    }
}
