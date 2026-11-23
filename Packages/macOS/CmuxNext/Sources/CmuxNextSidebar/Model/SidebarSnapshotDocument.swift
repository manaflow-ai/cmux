package import Foundation

/// The saved sidebars of this app's windows (`sidebar-snapshot-v1.json`),
/// most recently used window first. A cache, never a source of truth: a
/// missing, unreadable or newer-schema file only means the launch shows
/// placeholder rows until the daemon answers.
package nonisolated struct SidebarSnapshotDocument: Codable, Hashable, Sendable {
    package static let schemaVersion = 1
    /// Windows kept; older ones drop off the end.
    package static let windowLimit = 8

    package var schemaVersion = Self.schemaVersion
    package var windows: [Entry] = []

    package struct Entry: Codable, Hashable, Sendable {
        package var windowID: String
        package var snapshot: SidebarSnapshot
    }

    package init() {}

    /// The sidebar to draw first in window `windowID`: its own, else (for
    /// the window a launch opens before the saved window ids are known)
    /// the most recently used window's when `fallback` is true.
    package func snapshot(for windowID: String, fallback: Bool) -> SidebarSnapshot? {
        windows.first { $0.windowID == windowID }?.snapshot ?? (fallback ? windows.first?.snapshot : nil)
    }

    /// Saves `snapshot` for `windowID` and makes it the most recent window.
    /// Returns false when nothing changed.
    @discardableResult
    package mutating func record(_ snapshot: SidebarSnapshot, window windowID: String) -> Bool {
        let entry = Entry(windowID: windowID, snapshot: snapshot)
        guard windows.first != entry else { return false }
        windows.removeAll { $0.windowID == windowID }
        windows.insert(entry, at: 0)
        if windows.count > Self.windowLimit { windows.removeLast(windows.count - Self.windowLimit) }
        return true
    }

    /// Makes `windowID` the most recent window. Returns false when nothing changed.
    @discardableResult
    package mutating func touch(window windowID: String) -> Bool {
        guard windows.first?.windowID != windowID, let index = windows.firstIndex(where: { $0.windowID == windowID }) else { return false }
        windows.insert(windows.remove(at: index), at: 0)
        return true
    }

    /// Drops a window the user closed. Returns false when it had no entry.
    @discardableResult
    package mutating func forget(window windowID: String) -> Bool {
        let before = windows.count
        windows.removeAll { $0.windowID == windowID }
        return windows.count != before
    }

    /// What the writer did to bring a document under the file's size limit.
    package struct Compaction: Equatable, Sendable {
        package var bytesBefore: Int
        package var bytesAfter: Int
        package var limit: Int
        /// Rows kept only what places them (step 1).
        package var droppedRowDetail = false
        /// Least recently used windows dropped (step 2).
        package var droppedWindows = 0
        /// Rows dropped from the bottom of the most recent window (step 3).
        package var droppedRows = 0
    }

    /// The document encoded to at most `limit` bytes, and what was given up when it did not fit as is:
    /// first each row's second line, status block and progress (rows still restore in place, one line
    /// tall until the live tree arrives), then the least recently used windows, then rows from the
    /// bottom of the most recent window, the part its first frame shows least. The reader never sees a
    /// file it would refuse (`SidebarSnapshotFile.read`). At most windowLimit + 4 encodes.
    package func fitted(limit: Int) throws -> (data: Data, compaction: Compaction?) {
        let encoder = JSONEncoder()
        var data = try encoder.encode(self)
        guard data.count > limit else { return (data, nil) }
        var compaction = Compaction(bytesBefore: data.count, bytesAfter: data.count, limit: limit)
        var document = self
        document.windows = windows.map { Entry(windowID: $0.windowID, snapshot: $0.snapshot.compactingRows()) }
        compaction.droppedRowDetail = true
        data = try encoder.encode(document)
        while data.count > limit, document.windows.count > 1 {
            document.windows.removeLast()
            compaction.droppedWindows += 1
            data = try encoder.encode(document)
        }
        // Rows cost about the same each: keep the share that fits, with a margin, so this ends in a pass or two.
        var passes = 0
        while data.count > limit, let first = document.windows.first, first.snapshot.rowCount > 0, passes < 4 {
            passes += 1
            let rows = first.snapshot.rowCount
            let keep = min(rows - 1, Int(Double(rows) * Double(limit) / Double(data.count) * 0.95))
            document.windows[0].snapshot = first.snapshot.keepingFirstRows(keep)
            compaction.droppedRows += rows - document.windows[0].snapshot.rowCount
            data = try encoder.encode(document)
        }
        if data.count > limit {
            // Nothing row-sized is left to give up (a huge space bar): save no sidebar rather than one the reader refuses.
            compaction.droppedWindows += document.windows.count
            data = try encoder.encode(SidebarSnapshotDocument())
        }
        compaction.bytesAfter = data.count
        return (data, compaction)
    }
}
