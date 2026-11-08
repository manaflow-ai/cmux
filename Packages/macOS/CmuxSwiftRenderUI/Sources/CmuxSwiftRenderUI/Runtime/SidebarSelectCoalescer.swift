import CmuxSwiftRender
import Foundation

/// Drops superseded workspace selections during a click burst. A workspace
/// switch costs main-actor work (terminal view swap, ~100-250ms measured), so
/// clicking through rows fast serializes one switch per click and the last
/// click waits for all the earlier ones. Only the NEWEST queued select
/// matters: the sidebar paints each click optimistically, and the
/// intermediate switches are transient states the user has already clicked
/// past.
///
/// Usage (see the app's sidebar action dispatch): stamp each coalescable
/// action at enqueue on the dispatching thread; when the serial execution
/// lane dequeues it, run it only if its stamp is still the newest. Because
/// the lane is FIFO, the newest stamp always runs and the end state is the
/// last click, regardless of how many intermediates were skipped.
public final class SidebarSelectCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    public init() {}

    /// Registers a new coalescable action; returns its generation.
    public func stamp() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latest += 1
        return latest
    }

    /// True while no newer stamp has been issued.
    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == latest
    }

    /// Stamps a coalescable action, or returns nil for one that must always
    /// run. Only a SINGLE-command `workspace.select` coalesces: multi-command
    /// sequences keep their authored semantics, and every other method has
    /// effects beyond "which workspace is current".
    public func generation(for commands: [ActionCommand]) -> UInt64? {
        guard commands.count == 1,
              case let .cmux(method, _) = commands[0],
              method == "workspace.select" else { return nil }
        return stamp()
    }
}
