import Foundation

/// A validated OSC 7501 record kept for one terminal panel.
public struct ProgramStatusRecord: Equatable, Sendable {
    /// The record id, or an empty string for the root record.
    public let id: String
    /// The current protocol state.
    public let state: ProgramStatusState
    /// The blocked kind, when present.
    public let kind: ProgramStatusKind
    /// The current progress percentage for working or blocked records.
    public let progress: Int?
    /// The program name, before ancestor inheritance is applied.
    public let app: String?
    /// The human readable title.
    public let title: String?
    /// The human readable message.
    public let message: String?
    /// Monotonic update order used for least recently updated eviction.
    public let updateOrder: UInt64

    public init(
        id: String,
        state: ProgramStatusState,
        kind: ProgramStatusKind = .none,
        progress: Int? = nil,
        app: String? = nil,
        title: String? = nil,
        message: String? = nil,
        updateOrder: UInt64 = 0
    ) {
        self.id = id
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.message = message
        self.updateOrder = updateOrder
    }
}

/// The protocol state carried by a program status report.
public enum ProgramStatusState: String, CaseIterable, Equatable, Sendable {
    case idle
    case working
    case done
    case blocked
    case error
    case clear
}

/// The kind of input a blocked program needs.
public enum ProgramStatusKind: String, CaseIterable, Equatable, Sendable {
    case none
    case permission
    case question
    case auth
}

/// A report copied from the Ghostty callback before it enters the main actor.
public struct ProgramStatusReport: Equatable, Sendable {
    public let event: ProgramStatusEvent
    public let state: ProgramStatusState
    public let kind: ProgramStatusKind
    public let progress: Int?
    public let id: String?
    public let app: String?
    public let title: String?
    public let message: String?

    public init(
        event: ProgramStatusEvent = .report,
        state: ProgramStatusState,
        kind: ProgramStatusKind = .none,
        progress: Int? = nil,
        id: String? = nil,
        app: String? = nil,
        title: String? = nil,
        message: String? = nil
    ) {
        self.event = event
        self.state = state
        self.kind = kind
        self.progress = progress
        self.id = id
        self.app = app
        self.title = title
        self.message = message
    }
}

/// Lifecycle events that affect records without replacing a report.
public enum ProgramStatusEvent: String, Equatable, Sendable {
    case report
    case promptStart = "prompt_start"
}

/// The change kinds emitted when a terminal's program-status projection changes.
public enum ProgramStatusChange: String, Equatable, Sendable {
    case report
    case clear
    case promptStart = "prompt_start"
    case transientDrop = "transient_drop"
    case dismissed
    /// The terminal closed or left this workspace; its records are gone here.
    case removed
    /// A terminal moved into this workspace with the records it already had.
    case adopted
}

/// The safe, protocol-level fields exported for one program-status record.
///
/// Free-form OSC text and provider names stay in the sidebar projection and
/// are intentionally excluded from the event stream and its persistent log.
public struct ProgramStatusRecordSnapshot: Equatable, Sendable {
    /// The record id, or an empty string for the root record.
    public let id: String
    /// The current protocol state.
    public let state: ProgramStatusState
    /// The blocked kind, when present.
    public let kind: ProgramStatusKind
    /// The current progress percentage for working or blocked records.
    public let progress: Int?
    /// The monotonic record update sequence.
    public let updatedSequence: UInt64

    /// Creates a safe event snapshot from a stored record.
    public init(record: ProgramStatusRecord) {
        id = record.id
        state = record.state
        kind = record.kind
        progress = record.progress
        updatedSequence = record.updateOrder
    }
}

/// The complete event-stream projection for one program-status change.
public struct ProgramStatusChangedPayload: Equatable, Sendable {
    /// The reason the status projection changed.
    public let event: ProgramStatusChange
    /// The addressed record id, or `nil` when the change has no address.
    public let id: String?
    /// The updated addressed record for a report, when it exists.
    public let record: ProgramStatusRecordSnapshot?
    /// All current records in stable id order.
    public let records: [ProgramStatusRecordSnapshot]

    /// Builds a payload from a lifecycle change and the resulting store.
    public init(
        event: ProgramStatusChange,
        id: String? = nil,
        store: ProgramStatusRecordStore
    ) {
        self.event = event
        self.id = id
        if event == .report {
            record = store.record(id: id ?? "").map(ProgramStatusRecordSnapshot.init(record:))
        } else {
            record = nil
        }
        records = store.records.map(ProgramStatusRecordSnapshot.init(record:))
    }

    /// Builds a payload from an OSC 7501 report and the resulting store.
    public init(report: ProgramStatusReport, store: ProgramStatusRecordStore) {
        let event: ProgramStatusChange
        if report.state == .clear {
            event = .clear
        } else if report.event == .promptStart {
            event = .promptStart
        } else {
            event = .report
        }
        self.init(event: event, id: report.id, store: store)
    }
}

/// A bounded, value-type store implementing OSC 7501 record semantics.
public struct ProgramStatusRecordStore: Equatable, Sendable {
    public static let recordLimit = 256

    private var storage: [String: ProgramStatusRecord] = [:]
    private var nextUpdateOrder: UInt64 = 0

    public init() {}

    /// All records, including records whose state is idle.
    public var records: [ProgramStatusRecord] {
        storage.values.sorted { $0.id < $1.id }
    }

    /// Applies one report, replacing the addressed record completely.
    public mutating func apply(_ report: ProgramStatusReport) {
        if report.event == .promptStart {
            dropTransient()
            return
        }
        if report.state == .clear {
            if let id = report.id, !id.isEmpty {
                storage.keys.filter { $0 == id || $0.hasPrefix(id + "/") }.forEach { storage.removeValue(forKey: $0) }
            } else {
                storage.removeAll(keepingCapacity: true)
            }
            return
        }

        nextUpdateOrder &+= 1
        let id = report.id ?? ""
        let record = ProgramStatusRecord(
            id: id,
            state: report.state,
            kind: report.state == .blocked ? report.kind : .none,
            progress: (report.state == .working || report.state == .blocked) ? report.progress : nil,
            app: report.app,
            title: report.title,
            message: report.message,
            updateOrder: nextUpdateOrder
        )
        storage[id] = record
        if storage.count > Self.recordLimit,
           let oldest = storage.values.min(by: { $0.updateOrder < $1.updateOrder }) {
            storage.removeValue(forKey: oldest.id)
        }
    }

    /// Drops working and blocked records when a prompt begins or a child exits.
    public mutating func dropTransient() {
        storage = storage.filter { $0.value.state != .working && $0.value.state != .blocked }
    }

    /// Dismisses completed and failed records after the user returns to the panel.
    public mutating func dismissCompleted() {
        storage = storage.filter { $0.value.state != .done && $0.value.state != .error }
    }

    /// Returns the nearest inherited app name for a record.
    public func effectiveApp(for record: ProgramStatusRecord) -> String? {
        if let app = record.app { return app }
        var parent = record.id
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if let app = storage[parent]?.app { return app }
        }
        return storage[""]?.app
    }

    /// Returns the highest urgency record, excluding idle records.
    public func mostUrgentRecord() -> ProgramStatusRecord? {
        storage.values
            .filter { $0.state != .idle }
            .max { lhs, rhs in
                let left = Self.urgencyRank(lhs.state)
                let right = Self.urgencyRank(rhs.state)
                return left == right ? lhs.updateOrder < rhs.updateOrder : left < right
            }
    }

    /// Returns a record by id.
    public func record(id: String) -> ProgramStatusRecord? { storage[id] }

    /// Returns the sidebar urgency rank for a protocol state.
    public static func urgencyRank(_ state: ProgramStatusState) -> Int {
        switch state {
        case .blocked: 4
        case .error: 3
        case .working: 2
        case .done: 1
        case .idle, .clear: 0
        }
    }
}
