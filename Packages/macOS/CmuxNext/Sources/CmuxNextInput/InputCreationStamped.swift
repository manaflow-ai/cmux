/// A view that knows when it was made: a late key's log says how new the terminal that took it was
/// (`TerminalSurfaceView`).
public protocol InputCreationStamped: AnyObject {
    /// When the view was made (`CLOCK_UPTIME_RAW` nanoseconds).
    var createdNanos: UInt64 { get }
}
