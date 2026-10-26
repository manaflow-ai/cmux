import CmuxNextCompat

/// The process's category flags: the one word every trace point reads, and the keystroke-timing gate
/// (plans/cmux-next/chrome-parity/p09-observability.md section 3A and rule 5, task 128).
///
/// The word a trace point loads is the requested set (the black-box defaults, `trace.start`'s categories)
/// minus the key category while the key gate is closed: while secure keyboard entry is on or Ghostty
/// reports a password prompt, no per-key record is written, by the black box or by a local recording.
/// Chrome turns on `EnableSecureEventInput` for password fields the same way
/// (ui/base/cocoa/secure_password_input.h), and a trace point that is off costs one relaxed load and one
/// branch (`category_group_enabled`, base/trace_event/builtin_categories.h).
///
/// ```swift
/// categories.setMask(TraceCategories.blackBoxDefault)
/// categories.setKeyTimingSuppressed(true)   // a password prompt
/// categories.isEnabled(bit: TraceCategories.keyBit)   // false
/// ```
public final class TraceCategories: Sendable {
    /// The `key` category's bit (plans/cmux-next/trace.md "Release trace ring: category bits").
    public static let keyBit: UInt8 = 1
    /// The `input` category's bit: non-key input events (IME commits, pastes).
    public static let inputBit: UInt8 = 14
    /// What the black box records from launch: action, key, switch, create, cef, launch, daemon, hang, crash.
    public static let blackBoxDefault: UInt64 = 0x1FF
    /// The categories that time a person's typing: off while the key gate is closed.
    public static let keyTiming: UInt64 = 1 << UInt64(keyBit)
    /// The categories an upload never carries (``BlackboxUpload``): key timing and text-entry input events.
    public static let neverUploaded: UInt64 = keyTiming | 1 << UInt64(inputBit)

    /// What trace points read: ``requestedMask`` without ``keyTiming`` while the gate is closed.
    private let effective = Atomic<UInt64>(0)
    private let requested = Atomic<UInt64>(0)
    private let keyTimingSuppressed = Atomic<Bool>(false)

    /// Flags with `mask` requested and the key gate open.
    public init(mask: UInt64 = 0) {
        requested.store(mask, ordering: .sequentiallyConsistent)
        effective.store(mask, ordering: .sequentiallyConsistent)
    }

    /// The flags trace points read now.
    public var mask: UInt64 { effective.load(ordering: .relaxed) }

    /// The flags last asked for, before the key gate.
    public var requestedMask: UInt64 { requested.load(ordering: .sequentiallyConsistent) }

    /// Whether the key gate is closed (secure keyboard entry or a password prompt).
    public var isKeyTimingSuppressed: Bool { keyTimingSuppressed.load(ordering: .sequentiallyConsistent) }

    /// Whether category bit `bit` records: one relaxed load and one branch.
    @inline(__always)
    public func isEnabled(bit: UInt8) -> Bool {
        effective.load(ordering: .relaxed) & (1 << UInt64(bit & 63)) != 0
    }

    /// Asks for `mask` (launch defaults, `trace.start`, `trace.stop`); the key gate still applies.
    public func setMask(_ mask: UInt64) {
        requested.store(mask, ordering: .sequentiallyConsistent)
        publish()
    }

    /// Closes (`true`) or opens the key gate. Secure input turns on and off on the main thread; a
    /// recording can start on any thread, so ``publish()`` settles both writers without a lock.
    public func setKeyTimingSuppressed(_ suppressed: Bool) {
        keyTimingSuppressed.store(suppressed, ordering: .sequentiallyConsistent)
        publish()
    }

    /// Stores the word for the current request and gate, again until neither changed under it: the last
    /// store of any racing writer then matches the last change.
    private func publish() {
        // wakeup-allow: never waits for readiness; it runs again only when another writer changed the request or gate between these loads and the store.
        while true {
            let mask = requested.load(ordering: .sequentiallyConsistent)
            let suppressed = keyTimingSuppressed.load(ordering: .sequentiallyConsistent)
            effective.store(suppressed ? mask & ~Self.keyTiming : mask, ordering: .sequentiallyConsistent)
            if requested.load(ordering: .sequentiallyConsistent) == mask,
               keyTimingSuppressed.load(ordering: .sequentiallyConsistent) == suppressed { return }
        }
    }
}

/// One decoded black-box record joined with its ring name-table entry: what the upload decoder reads
/// (plans/cmux-next/trace.md "Release trace ring v1": record and name entry).
public struct BlackboxRecord: Sendable, Equatable {
    /// A name-table entry's kind byte.
    public enum NameKind: UInt8, Sendable, Equatable {
        /// A fixed catalog name (`SignpostName`).
        case catalog = 1
        /// A name interned at run time (`TraceRuntime.InternedName`).
        case interned = 2
        /// A category entry.
        case category = 3
    }

    /// A record's name-table entry.
    public struct Name: Sendable, Equatable {
        /// The entry's UTF-8 text.
        public var text: String
        /// The entry's kind.
        public var kind: NameKind
        /// The entry's category bit.
        public var categoryBit: UInt8

        /// An entry from its parts.
        public init(text: String, kind: NameKind, categoryBit: UInt8) {
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

/// The black-box decoder every upload uses (hang reports' `blackbox[]`, the Sentry `blackbox.txt`):
/// catalog names and numbers only, and never a record that times a key (rule 5, task 128). Chrome's
/// background traces pass the same kind of allow-list before upload
/// (services/tracing/public/cpp/perfetto/privacy_filtering_check.cc).
///
/// It drops a record when its name is not a catalog name, its category is in
/// ``TraceCategories/neverUploaded``, it is a flow record (a flow id links one key press across
/// processes), or its name is a per-key one: `key.*`, a PTY hop (a `pty` name part), one event per
/// input (`cef.host_input`, `remote.input`, `remote.present`) or `frame.present_estimate` (its arg0 is
/// the key's flow id).
///
/// ```swift
/// let events = BlackboxUpload().events(records)   // at most 512, oldest first
/// ```
public struct BlackboxUpload: Sendable {
    /// The most events one upload carries.
    public static let maxEvents = 512
    private static let perKeyNames: Set<String> = ["frame.present_estimate", "cef.host_input", "remote.input", "remote.present"]
    private static let flowPhases: Set<UInt8> = [TraceRuntime.Phase.flowOut.rawValue, TraceRuntime.Phase.flowIn.rawValue]

    /// The most events ``events(_:)`` keeps.
    public let limit: Int

    /// A decoder that keeps at most `limit` events.
    public init(limit: Int = BlackboxUpload.maxEvents) {
        self.limit = max(0, limit)
    }

    /// Whether `record` may leave the Mac.
    public func keeps(_ record: BlackboxRecord) -> Bool {
        guard let name = record.name, name.kind == .catalog, name.categoryBit < 64,
              TraceCategories.neverUploaded & (1 << UInt64(name.categoryBit)) == 0,
              !Self.flowPhases.contains(record.phaseCode),
              !Self.perKeyNames.contains(name.text), !name.text.hasPrefix("key.") else { return false }
        return !name.text.split(whereSeparator: { $0 == "." || $0 == "_" }).contains("pty")
    }

    /// The newest ``limit`` records that may leave the Mac, oldest first.
    public func events(_ records: [BlackboxRecord]) -> [BlackboxRecord] {
        Array(records.filter(keeps).sorted { $0.timestamp < $1.timestamp }.suffix(limit))
    }

    /// ``events(_:)`` as `blackbox.txt` lines: `<t_ns> <process> <name> <phase> <arg0> <arg1>`.
    public func text(_ records: [BlackboxRecord]) -> String {
        events(records).map { record in
            let phase = Unicode.Scalar(record.phaseCode).escaped(asASCII: true)
            return "\(record.timestamp) \(record.process) \(record.name?.text ?? "") \(phase) \(record.arg0) \(record.arg1)\n"
        }.joined()
    }

    /// The crash event's `blackbox.txt`, or nil without the hang-reports opt-in or when nothing may leave.
    public func crashAttachmentText(_ records: [BlackboxRecord], hangReportsOptIn: Bool) -> String? {
        guard hangReportsOptIn else { return nil }
        let text = text(records)
        return text.isEmpty ? nil : text
    }
}
