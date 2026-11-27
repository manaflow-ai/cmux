import CmuxSettings
import Foundation
import Observation

/// Bounded ring-buffer of settings-write failures, surfaced to the UI.
///
/// Models call ``record(_:keyID:)`` whenever a write to a backing store
/// fails. The settings window renders the recent entries as a banner so
/// users see the failure instead of having the UI silently revert on the
/// next read. `@Observable`, lives on the runtime, retained by
/// ``EnvironmentValues/settingsErrorLog``.
@MainActor
@Observable
public final class SettingsErrorLog {
    /// One recorded failure.
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: UUID
        /// The dotted ``AnySettingKey/id`` of the setting that failed.
        public let keyID: String
        /// Localized error description.
        public let message: String
        /// When the failure was recorded.
        public let timestamp: Date

        public init(keyID: String, message: String, timestamp: Date = Date()) {
            self.id = UUID()
            self.keyID = keyID
            self.message = message
            self.timestamp = timestamp
        }
    }

    /// Maximum number of entries kept. Older entries are discarded.
    public let capacity: Int

    public private(set) var entries: [Entry] = []

    public init(capacity: Int = 32) {
        self.capacity = capacity
    }

    /// Pushes a new entry. If the buffer is at ``capacity``, the oldest
    /// entry is dropped.
    public func record(_ error: Error, keyID: String) {
        let entry = Entry(keyID: keyID, message: error.localizedDescription)
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Removes the entry with the given id. No-op if not present.
    public func dismiss(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Clears all entries.
    public func clear() {
        entries.removeAll()
    }
}
