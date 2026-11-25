import CmuxNextCompat
public import CmuxNextSettings

/// One section of Settings' host lists (`cmux.settings.host.lists`): the top-level keys it fills,
/// built by `read` on the main actor from the observable stores it reads.
///
/// hq#20297: the page's watch (`cmux.settings.host.changed`) used to rebuild the whole lists on
/// main after any change to anything they read (rooms, machines, devices parsed back from a
/// string, browser profiles, every theme level's choice, the Ghostty preview, diagnostics). Now
/// each section is observed on its own (``watch(_:onEvent:)``): a change rebuilds only the
/// sections that read it, and the event still carries the whole lists, the others from cache,
/// so the page's protocol is unchanged.
public struct SettingsHostSection: Sendable {
    public let name: String
    public let read: @MainActor @Sendable () -> [String: JSONValue]

    public init(name: String, read: @escaping @MainActor @Sendable () -> [String: JSONValue]) {
        self.name = name
        self.read = read
    }

    /// The whole lists from each section's keys.
    public static func merged(_ parts: [[String: JSONValue]]) -> JSONValue {
        .object(parts.reduce(into: [:]) { whole, part in whole.merge(part) { _, new in new } })
    }

    /// One event per change of the lists, carrying them whole: each section has its own
    /// observation, so a change rebuilds only the sections that read it. The baseline is read
    /// once per section at the start and not sent; changes to several sections in one main-actor
    /// turn send one event.
    @MainActor
    public static func watch(_ sections: [SettingsHostSection], onEvent: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription {
        let state = WatchState(count: sections.count, onEvent: onEvent)
        let tasks = sections.enumerated().map { index, section in
            // task-owner: the page's host-changed subscription; event-driven (Observation), cancelled by its
            // PageSubscription. Inherits the main actor: each evaluation runs as an ObservationStream task.
            Task {
                let (first, later) = ObservationStream.current { section.read() }
                state.baseline(index, first)
                for await value in later {
                    state.changed(index, value)
                }
            }
        }
        return PageSubscription {
            state.cancelled = true
            tasks.forEach { $0.cancel() }
        }
    }

    /// The sections' last values and the one pending send.
    @MainActor
    private final class WatchState {
        var parts: [[String: JSONValue]?]
        var waitingForBaselines: Int
        var dirty = false
        var sendQueued = false
        var cancelled = false
        let onEvent: @MainActor (JSONValue) -> Void

        init(count: Int, onEvent: @escaping @MainActor (JSONValue) -> Void) {
            parts = Array(repeating: nil, count: count)
            waitingForBaselines = count
            self.onEvent = onEvent
        }

        func baseline(_ index: Int, _ value: [String: JSONValue]) {
            parts[index] = value
            waitingForBaselines -= 1
            if waitingForBaselines == 0, dirty { queueSend() }
        }

        func changed(_ index: Int, _ value: [String: JSONValue]) {
            guard parts[index] != value else { return }
            parts[index] = value
            dirty = true
            if waitingForBaselines == 0 { queueSend() }
        }

        private func queueSend() {
            guard !sendQueued else { return }
            sendQueued = true
            // task-owner: this WatchState; ends after one send (none once cancelled), on the main actor it inherits.
            Task {
                self.sendQueued = false
                guard !self.cancelled, self.dirty else { return }
                self.dirty = false
                self.onEvent(SettingsHostSection.merged(self.parts.compactMap { $0 }))
            }
        }
    }
}
