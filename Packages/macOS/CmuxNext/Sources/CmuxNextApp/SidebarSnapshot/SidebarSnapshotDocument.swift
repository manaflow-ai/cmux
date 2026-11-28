import Foundation

/// The saved sidebars of this app's windows (`sidebar-snapshot-v1.json`),
/// most recently used window first. A cache, never a source of truth: a
/// missing, unreadable or newer-schema file only means the launch shows
/// placeholder rows until the daemon answers.
nonisolated struct SidebarSnapshotDocument: Codable, Hashable, Sendable {
    static let schemaVersion = 1
    /// Windows kept; older ones drop off the end.
    static let windowLimit = 8

    var schemaVersion = Self.schemaVersion
    var windows: [Entry] = []

    struct Entry: Codable, Hashable, Sendable {
        var windowID: String
        var snapshot: SidebarSnapshot
    }

    init() {}

    /// The sidebar to draw first in window `windowID`: its own, else (for
    /// the window a launch opens before the saved window ids are known)
    /// the most recently used window's when `fallback` is true.
    func snapshot(for windowID: String, fallback: Bool) -> SidebarSnapshot? {
        windows.first { $0.windowID == windowID }?.snapshot ?? (fallback ? windows.first?.snapshot : nil)
    }

    /// Saves `snapshot` for `windowID` and makes it the most recent window.
    /// Returns false when nothing changed.
    @discardableResult
    mutating func record(_ snapshot: SidebarSnapshot, window windowID: String) -> Bool {
        let entry = Entry(windowID: windowID, snapshot: snapshot)
        guard windows.first != entry else { return false }
        windows.removeAll { $0.windowID == windowID }
        windows.insert(entry, at: 0)
        if windows.count > Self.windowLimit { windows.removeLast(windows.count - Self.windowLimit) }
        return true
    }

    /// Makes `windowID` the most recent window. Returns false when nothing changed.
    @discardableResult
    mutating func touch(window windowID: String) -> Bool {
        guard windows.first?.windowID != windowID, let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return false }
        windows.insert(windows.remove(at: index), at: 0)
        return true
    }

    /// Drops a window the user closed. Returns false when it had no entry.
    @discardableResult
    mutating func forget(window windowID: String) -> Bool {
        let before = windows.count
        windows.removeAll { $0.windowID == windowID }
        return windows.count != before
    }
}
