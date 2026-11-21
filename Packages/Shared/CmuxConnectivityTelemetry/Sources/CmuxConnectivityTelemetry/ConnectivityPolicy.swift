import Foundation

/// What a device keeps of its connectivity events, per ``ConnectivityAudience``.
///
/// - ``ConnectivityAudience/team``: every event, every field, its free-text detail; no
///   sampling, no budget.
/// - ``ConnectivityAudience/everyone``: free text is removed (``ConnectivityEvent/detail`` and
///   every ``ConnectivityEvent/Value/text`` field, and any field whose name is not one ASCII
///   snake_case word). Every failure is kept; an info or success step is kept once per
///   ``Configuration/sampleEvery`` occurrences of its ``ConnectivityEvent/samplingKey`` (the first, then
///   every Nth), its record saying the rate. At most ``Configuration/everyonePerHour`` records
///   are kept per sliding hour; the next kept record counts what was dropped.
public struct ConnectivityPolicy: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Everyone's info and success steps: one kept per this many of a key.
        public var sampleEvery: Int
        /// Everyone's records per sliding hour.
        public var everyonePerHour: Int

        public init(sampleEvery: Int = 10, everyonePerHour: Int = 120) {
            self.sampleEvery = max(1, sampleEvery)
            self.everyonePerHour = max(0, everyonePerHour)
        }
    }

    public let configuration: Configuration
    private var seen: [String: Int] = [:]
    private var window: [Date] = []
    private var dropped = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The record kept of `event` for `audience`, or nil when it is not kept.
    public mutating func admit(_ event: ConnectivityEvent, audience: ConnectivityAudience) -> ConnectivityRecord? {
        switch audience {
        case .team:
            return ConnectivityRecord(date: event.date, audience: .team, area: event.area, name: event.name,
                                      outcome: event.outcome, fields: event.fields, detail: event.detail,
                                      sampleRate: 1, droppedBefore: 0)
        case .everyone:
            var sampleRate = 1
            if event.outcome != .failure {
                let count = seen[event.samplingKey, default: 0]
                seen[event.samplingKey] = count + 1
                guard count % configuration.sampleEvery == 0 else { return nil }
                sampleRate = configuration.sampleEvery
            }
            let hour: TimeInterval = 3600
            window.removeAll { event.date.timeIntervalSince($0) >= hour }
            guard window.count < configuration.everyonePerHour else {
                dropped += 1
                return nil
            }
            window.append(event.date)
            let droppedBefore = dropped
            dropped = 0
            return ConnectivityRecord(date: event.date, audience: .everyone, area: event.area, name: event.name,
                                      outcome: event.outcome, fields: event.fields.filter { $0.value.isFixedVocabulary && ConnectivityEvent.Value.isSafeKey($0.key) },
                                      detail: nil, sampleRate: sampleRate, droppedBefore: droppedBefore)
        }
    }

    /// Forgets the sampling counts and the budget (a new account).
    public mutating func reset() {
        seen = [:]
        window = []
        dropped = 0
    }
}
