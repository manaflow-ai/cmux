package import CmuxNextCompat
public import Foundation

/// Bare words the ``IntranetHostProbe`` found to be intranet hosts. The
/// synchronous ``OmniboxResolver`` reads it on every keystroke and on Enter,
/// so a word that resolved loads `http://word/` instead of searching. One
/// per suggestion engine, in memory only.
public nonisolated final class IntranetHostMemory: Sendable {
    // Read synchronously by the Sendable resolver (no async context on
    // Enter); a tiny set behind a lock, as HostTypoMemory.
    private let hosts = Mutex<Set<String>>([])

    public init() {}

    /// Whether `label` (any case) resolved last time it was checked.
    public func isIntranetHost(_ label: String) -> Bool {
        hosts.withLock { $0.contains(label.lowercased()) }
    }

    /// Records the newest answer for `label`.
    public func record(_ label: String, resolves: Bool) {
        let key = label.lowercased()
        hosts.withLock { set in
            if resolves {
                _ = set.insert(key)
            } else {
                _ = set.remove(key)
            }
        }
    }
}
