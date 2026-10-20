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

    /// Ids (paths) of the change set's files that are viewed.
    public func viewedIDs(in changeSet: DiffChangeSet) -> Set<String> {
        Set(changeSet.files.filter(isViewed).map(\.id))
    }

    /// `path#fingerprint`: FNV-1a over the diff lines (stable across launches, unlike `hashValue`).
    public static func key(for file: DiffFile) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0x0A
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix(file.status.rawValue)
        for line in file.lines {
            mix("\(line.kind)")
            mix(line.text)
        }
        return file.path + "#" + String(hash, radix: 16)
    }
}
