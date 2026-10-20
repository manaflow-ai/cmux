/// What Sleepy Mode holds while it shows: the Mac and its display stay awake.
/// ``SleepyKeepAwakeActivity`` holds it for real; tests pass a fake.
@MainActor
protocol SleepyKeepAwakeHolding: AnyObject {
    /// True while the hold is on.
    var isHolding: Bool { get }
    /// Starts the hold. A second call does nothing.
    func begin()
    /// Ends the hold. Does nothing when none is on.
    func end()
}
