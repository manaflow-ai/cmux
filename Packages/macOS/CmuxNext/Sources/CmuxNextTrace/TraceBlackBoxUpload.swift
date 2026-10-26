/// The black-box decoder every upload uses: a hang report's `blackbox[]` and the Sentry crash event's
/// `blackbox.txt` (plans/cmux-next/chrome-parity/p09-observability.md rule 5, task 128). It keeps catalog names
/// and numbers only, and never a record that times a key, so a person's typing rhythm never leaves the Mac.
/// Chrome's background traces pass the same kind of allow-list before upload
/// (services/tracing/public/cpp/perfetto/privacy_filtering_check.cc).
///
/// A record is dropped when:
/// - its name is not a catalog name (an interned name, or an id the ring's table lacks);
/// - its category is in ``TraceCategories/neverUploaded`` (key timing, per-input events);
/// - it is a flow record (a flow id links one key press across processes);
/// - its name is per key: `key.*`, a PTY hop (a `pty` name part, as `key.echo.host_pty_read` or
///   `holder.pty.read`), one event per input (`cef.host_input`, `remote.input`, `remote.present`) or
///   `frame.present_estimate` (its arg0 is the key's flow id).
///
/// ```swift
/// let records = TraceBlackBoxUpload.records(of: image)       // a decoded ring
/// let events = TraceBlackBoxUpload().events(app + daemon)    // at most 512, oldest first
/// ```
public struct TraceBlackBoxUpload: Sendable {
    /// One ring record joined with its ring's name entry and the process that wrote it.
    public struct Record: Sendable, Equatable {
        /// A record's name-table entry.
        public struct Name: Sendable, Equatable {
            /// The entry's UTF-8 text.
            public var text: String
            /// The entry's kind, or nil for a code this build does not know.
            public var kind: TraceRing.NameEntry.Kind?
            /// The entry's category bit.
            public var categoryBit: UInt8

            /// An entry from its parts.
            public init(text: String, kind: TraceRing.NameEntry.Kind?, categoryBit: UInt8) {
                self.text = text
                self.kind = kind
                self.categoryBit = categoryBit
            }
        }

        /// The process whose ring holds the record.
        public var process: TraceRuntime.Role
        /// Trace clock nanoseconds.
        public var timestamp: UInt64
        /// The record's name entry, or nil when the id is not in the ring's table.
        public var name: Name?
        /// The raw phase byte.
        public var phaseCode: UInt8
        /// The raw flags byte.
        public var flags: UInt8
        /// The first argument.
        public var arg0: UInt64
        /// The second argument.
        public var arg1: UInt64

        /// A record from its parts.
        public init(process: TraceRuntime.Role, timestamp: UInt64, name: Name?, phaseCode: UInt8, flags: UInt8 = 0,
                    arg0: UInt64 = 0, arg1: UInt64 = 0) {
            self.process = process
            self.timestamp = timestamp
            self.name = name
            self.phaseCode = phaseCode
            self.flags = flags
            self.arg0 = arg0
            self.arg1 = arg1
        }
    }

    /// The most events one upload carries (a hang report's `blackbox[]` cap).
    public static let maxEvents = 512
    private static let perInputNames: Set<String> = ["frame.present_estimate", "cef.host_input", "remote.input", "remote.present"]
    private static let flowPhases: Set<UInt8> = [TraceRecord.Phase.flowOut.rawValue, TraceRecord.Phase.flowIn.rawValue]

    /// The most events ``events(_:)`` keeps.
    public let limit: Int

    /// A decoder that keeps at most `limit` events.
    public init(limit: Int = TraceBlackBoxUpload.maxEvents) {
        self.limit = max(0, limit)
    }

    /// The records of a decoded ring, each named from the ring's own table; empty for a role this build does
    /// not know.
    public static func records(of image: TraceRing.Image) -> [Record] {
        guard let process = TraceRuntime.Role(rawValue: image.header.roleCode) else { return [] }
        return image.records.map { record in
            let entry = image.namesByID[record.name]
            return Record(process: process, timestamp: record.timestamp,
                          name: entry.map { Record.Name(text: $0.text, kind: $0.kind, categoryBit: $0.category) },
                          phaseCode: record.phaseCode, flags: record.flags, arg0: record.arg0, arg1: record.arg1)
        }
    }

    /// Whether `record` may leave the Mac.
    public func keeps(_ record: Record) -> Bool {
        guard let name = record.name, name.kind == .catalog,
              name.categoryBit < 64, !TraceCategories.neverUploaded.contains(bit: name.categoryBit),
              !Self.flowPhases.contains(record.phaseCode),
              !Self.perInputNames.contains(name.text), !name.text.hasPrefix("key.") else { return false }
        return !name.text.split(whereSeparator: { $0 == "." || $0 == "_" }).contains("pty")
    }

    /// The newest ``limit`` records that may leave the Mac, oldest first.
    public func events(_ records: [Record]) -> [Record] {
        Array(records.filter(keeps).sorted { $0.timestamp < $1.timestamp }.suffix(limit))
    }

    /// ``events(_:)`` as `blackbox.txt` lines: `<t_ns> <process> <name> <phase> <arg0> <arg1>`.
    public func text(_ records: [Record]) -> String {
        events(records).map { record in
            let phase = Unicode.Scalar(record.phaseCode).escaped(asASCII: true)
            let process = record.process.ringRole.fileStem
            return "\(record.timestamp) \(process) \(record.name?.text ?? "") \(phase) \(record.arg0) \(record.arg1)\n"
        }.joined()
    }

    /// The crash event's `blackbox.txt`: nil without the hang-reports opt-in or when no record may leave.
    public func crashAttachmentText(_ records: [Record], hangReportsOptIn: Bool) -> String? {
        guard hangReportsOptIn else { return nil }
        let text = text(records)
        return text.isEmpty ? nil : text
    }
}
