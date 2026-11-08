import Foundation

/// Tracks the terminal files chip's mount state and turns raw count updates
/// into mount transitions.
///
/// Shows are immediate; a zero count only *schedules* a hide so the caller can
/// wait out a grace period before unmounting. The visible count dips to zero
/// transiently all the time — streaming output scrolls paths out of the
/// viewport between scans, and reconnects reset the artifact capabilities —
/// and unmounting on every dip flickers the chip. Disabling the chip still
/// hides immediately.
struct TerminalArtifactChipVisibilityState: Sendable, Equatable {
    enum Transition: Sendable, Equatable {
        /// Nothing to do; the mounted state already matches.
        case none
        /// Mount or refresh the chip with this count and cancel any pending hide.
        case mount(count: Int)
        /// Start the hide grace period; unmount only if no positive count
        /// arrives before it elapses.
        case scheduleHide
        /// Unmount immediately (the chip was disabled).
        case hideNow
    }

    private enum Mount: Sendable, Equatable {
        case unmounted
        case mounted(count: Int)
        /// Still mounted, showing the last count, waiting out the hide grace.
        case hidePending
    }

    private var mount: Mount = .unmounted

    mutating func update(count: Int, enabled: Bool) -> Transition {
        guard enabled else {
            guard mount != .unmounted else { return .none }
            mount = .unmounted
            return .hideNow
        }
        guard count > 0 else {
            switch mount {
            case .unmounted, .hidePending:
                return .none
            case .mounted:
                mount = .hidePending
                return .scheduleHide
            }
        }
        if case .mounted(let mountedCount) = mount, mountedCount == count {
            return .none
        }
        mount = .mounted(count: count)
        return .mount(count: count)
    }

    /// The hide grace period elapsed and the chip was unmounted.
    mutating func hideCompleted() {
        guard mount == .hidePending else { return }
        mount = .unmounted
    }

    /// The chip was torn down outside the update flow (dismantle).
    mutating func reset() {
        mount = .unmounted
    }
}
