/// The points inside ``RetryWake`` where a test must act to reproduce a race
/// (``RetryWake/init(owner:ledger:probe:)``). The app passes none.
struct RetryWakeProbe: Sendable {
    /// After the folder to watch was chosen and opened, before its watch is
    /// live: a test makes a deeper folder or the file there.
    var folderChosen: @Sendable (_ folder: String) -> Void = { _ in }
    /// A wait parked with `delay` (nil: no timer, events only).
    var parked: @Sendable (_ delay: Duration?) -> Void = { _ in }
}
