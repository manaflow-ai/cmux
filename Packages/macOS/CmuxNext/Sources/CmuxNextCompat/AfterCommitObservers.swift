public import CoreFoundation

/// cmux's own main run-loop observers that run after the Core Animation commit and lay out,
/// display and commit nothing: they only time the pass or stamp a heartbeat (``MainThreadWatchdog``'s
/// before-waiting stamp, the render pass meter's end, the debug frame probe's sleep) or keep the
/// cursor. Each is a block observer at `CFIndex.max`, so its dump entry prints only a block
/// trampoline (`__CFRunLoopObserverWithHandlerPerform`) and cannot be told apart by name from an
/// observer that does draw. The commit-boundary audit (`CommitBoundaryAudit`, `debug.commit_boundary`)
/// reads this list by address and does not count these as late.
///
/// Register an observer when it is added and remove it when it is invalidated: an address freed by
/// an invalidated observer can come back for another one.
///
/// ```swift
/// CFRunLoopAddObserver(CFRunLoopGetMain(), last, .commonModes)
/// AfterCommitObservers.register(last)
/// // ...
/// AfterCommitObservers.remove(last)
/// CFRunLoopObserverInvalidate(last)
/// ```
public nonisolated enum AfterCommitObservers {
    private static let addresses = Mutex<Set<UInt>>([])

    /// Marks `observer` as one that draws and commits nothing after the commit.
    public static func register(_ observer: CFRunLoopObserver) {
        let address = address(of: observer)
        addresses.withLock { _ = $0.insert(address) }
    }

    /// Unmarks `observer`; call it before invalidating or releasing it.
    public static func remove(_ observer: CFRunLoopObserver) {
        let address = address(of: observer)
        addresses.withLock { _ = $0.remove(address) }
    }

    /// Whether the observer at `address` (the `0x...` after `<CFRunLoopObserver` in a run loop's
    /// `CFCopyDescription`) is registered.
    public static func contains(address: UInt) -> Bool {
        addresses.withLock { $0.contains(address) }
    }

    private static func address(of observer: CFRunLoopObserver) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(observer).toOpaque())
    }
}
