import CmuxNextCompat
import Foundation

/// What this app knows of the acpmux daemons it starts on this Mac, kept for the whole launch. One
/// per app (`AppServices` makes it), handed to every ``AcpmuxHost`` and to Settings' daemon line
/// (``AcpmuxDaemonSummary/current(_:daemons:)``), so a handoff one host starts shows in that line
/// and a second Restart acpmux from another pane finds the first:
///
/// - the homes whose daemon a handoff or a takeover is stopping, until the lookup that starts the
///   bundled one settles (``mark(home:restarting:)``);
/// - the daemons (by pid) a person asked to replace with Restart acpmux, while that runs
///   (``AcpmuxSocketOwner/takeOver(environment:owner:daemons:)``): two clicks never stop two.
public nonisolated final class AcpmuxLocalDaemons: Sendable {
    /// Homes (standardized paths) whose daemon a handoff is stopping.
    private let restartingHomes = Mutex<Set<String>>([])
    /// Daemons (by pid) a Restart acpmux is stopping.
    private let stopping = Mutex<Set<Int32>>([])

    /// The app's one (`AppServices` makes it), or a test's own.
    public init() {}

    /// Notes that a handoff is stopping the daemon of `home`, or that it settled: its shutdown
    /// failed, the old daemon did not exit, or the lookup that starts the bundled one ended.
    func mark(home: URL, restarting: Bool) {
        let path = home.standardizedFileURL.path
        restartingHomes.withLock { homes in
            if restarting {
                _ = homes.insert(path)
            } else {
                _ = homes.remove(path)
            }
        }
    }

    /// Whether a handoff is stopping the daemon of `home` (``mark(home:restarting:)``).
    func isRestarting(home: URL) -> Bool {
        let path = home.standardizedFileURL.path
        return restartingHomes.withLock { $0.contains(path) }
    }

    /// Claims the stop of daemon `pid` for one Restart acpmux; false while another one stops it.
    func claimStop(_ pid: Int32) -> Bool {
        stopping.withLock { $0.insert(pid).inserted }
    }

    /// Ends the claim ``claimStop(_:)`` made.
    func endStop(_ pid: Int32) {
        _ = stopping.withLock { $0.remove(pid) }
    }
}
