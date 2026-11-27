import Foundation
import Observation

/// Which diff files the person has marked viewed: one model for every place a diff shows
/// (the transcript's turn card and diff snippets, the Changes list, Review and the file
/// screen), persisted across relaunch.
///
/// A file is keyed by its path and a fingerprint of its diff lines, so the mark belongs to
/// that turn's version of the file: the same edit is viewed wherever it appears (its turn's
/// Changes and the chat's "Agent edits"), and a later edit to the file starts unviewed, as
/// on GitHub.
@MainActor
@Observable
public final class DiffViewedStore {
    public static let shared = DiffViewedStore(defaults: .standard)

    /// UserDefaults key of the persisted marks.
    public static let storageKey = "cmuxMobile.diff.viewed"
    /// Marks kept (oldest dropped first).
    static let limit = 2000

    private let defaults: UserDefaults
    /// Viewed keys, oldest first.
    private var order: [String]
    private var marks: Set<String>

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.storageKey) ?? []
        order = stored
        marks = Set(stored)
    }

    public func isViewed(_ file: DiffFile) -> Bool {
        marks.contains(Self.key(for: file))
    }

    /// Whether the file with this `key(for:)` is viewed: O(1) for a caller that keeps the key
    /// (the key hashes every line of the file).
    public func isViewed(key: String) -> Bool {
        marks.contains(key)
    }

    public func setViewed(_ viewed: Bool, _ file: DiffFile) {
        let key = Self.key(for: file)
        guard viewed != marks.contains(key) else { return }
        if viewed {
            marks.insert(key)
            order.append(key)
            if order.count > Self.limit {
                let dropped = order.prefix(order.count - Self.limit)
                marks.subtract(dropped)
                order.removeFirst(dropped.count)
            }
        } else {
            marks.remove(key)
            order.removeAll { $0 == key }
        }
        defaults.set(order, forKey: Self.storageKey)
    }

    public func toggle(_ file: DiffFile) {
        setViewed(!isViewed(file), file)
    }

    /// Ids (paths) of the change set's files that are viewed: one set lookup per file.
    public func viewedIDs(in changeSet: DiffChangeSet) -> Set<String> {
        var ids = Set<String>()
        for file in changeSet.files where marks.contains(Self.key(for: file)) { ids.insert(file.id) }
        return ids
    }

    /// `path#fingerprint`: FNV-1a over the diff lines (stable across launches, unlike `hashValue`),
    /// hashed once when the file's content is set (`DiffFile.contentHash`).
    public nonisolated static func key(for file: DiffFile) -> String {
        file.path + "#" + String(file.contentHash, radix: 16)
    }
}
