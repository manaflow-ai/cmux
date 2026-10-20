import CmuxCore
import Foundation

/// Per-process enrichment reads (name, path, cmux scope) kept between
/// censuses, keyed by PID and exec identity.
///
/// An idle machine's census would otherwise re-read every process's argv and
/// environment (`KERN_PROCARGS2`) on every request. An entry is reused only
/// for the same process image: an exec or a reused PID changes the key, so
/// absent scope is never carried across an exec. Entries also expire after
/// ``maximumAge`` and drop out when their process leaves the census.
struct CmuxTopProcessEnrichmentMemo: Sendable {
    /// One process image.
    struct Key: Hashable, Sendable {
        let pid: Int
        let identity: CmuxTopProcessExecIdentity
    }

    /// A process's name and executable path.
    struct Details: Sendable {
        let name: String
        let path: String?
    }

    /// What one image's reads returned; a nil field was not read.
    struct Entry: Sendable {
        var details: Details?
        /// The resolved scope (`.some(nil)`: the image has none).
        var scope: CmuxTopProcessScope??
        let readAt: Date
    }

    /// Seconds a read is reused, from the census that read it.
    static let maximumAge: TimeInterval = 120

    private(set) var entries: [Key: Entry] = [:]

    /// The entry for `key` still young at `date`, or nil.
    func entry(for key: Key, at date: Date) -> Entry? {
        guard let entry = entries[key], date.timeIntervalSince(entry.readAt) < Self.maximumAge else {
            return nil
        }
        return entry
    }

    /// Records `entry` for `key`.
    mutating func set(_ entry: Entry, for key: Key) {
        entries[key] = entry
    }
}
