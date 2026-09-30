import Darwin
import Synchronization

/// The input journal (plans/cmux-next/input-spec.md section 3): a bounded
/// ring of every input event and every focus and attach transition, with
/// monotonic timestamps, so a reported desync comes with the exact sequence
/// that produced it.
///
/// Process-wide diagnostics like the main-thread watchdog, not model state.
/// Writers call from any thread (attach drivers run off the main actor);
/// one short lock guards the ring. Disabled, every call is one relaxed
/// atomic load: record payloads are built only behind ``isEnabled``.
nonisolated final class InputJournal: Sendable {
    static let shared = InputJournal()

    /// Default ring size: minutes of typing, seconds of dragging (drags and
    /// scrolls are merged, see ``appendMouse``).
    static let defaultCapacity = 4_096

    private struct Ring {
        var entries: [InputJournalEntry] = []
        /// Index of the oldest entry once the ring is full.
        var head = 0
        var nextSeq: UInt64 = 1
        var overwritten: UInt64 = 0
        var capacity: Int
    }

    private let enabled = Atomic<Bool>(false)
    private let characters = Atomic<Bool>(false)
    private let ring: Mutex<Ring>

    init(capacity: Int = InputJournal.defaultCapacity) {
        ring = Mutex(Ring(capacity: max(capacity, 16)))
    }

    /// Recording is on (debug and dogfood builds, or opted in).
    var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    /// Key characters are recorded (explicit user opt-in only).
    var recordsCharacters: Bool { characters.load(ordering: .relaxed) }

    func configure(_ policy: InputJournalPolicy) {
        enabled.store(policy.enabled, ordering: .relaxed)
        characters.store(policy.enabled && policy.recordsCharacters, ordering: .relaxed)
    }

    // MARK: Writing

    /// Appends a record. `kind` is evaluated only while enabled.
    func append(window: String?, _ kind: @autoclosure () -> InputJournalEntry.Kind) {
        guard isEnabled else { return }
        let record = kind()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        ring.withLock { ring in
            Self.push(InputJournalEntry(seq: ring.nextSeq, uptimeNanos: now, window: window, kind: record), into: &ring)
        }
    }

    /// Appends a mouse record, merging a drag or scroll into the previous
    /// entry when that is the same run (same window, phase and button), so
    /// a long drag does not flush the history that led to it.
    func appendMouse(window: String?, _ mouse: @autoclosure () -> InputJournalEntry.Mouse) {
        guard isEnabled else { return }
        let record = mouse()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        ring.withLock { ring in
            if record.phase == .drag || record.phase == .scroll, let last = Self.lastIndex(of: ring),
               case .mouse(var previous) = ring.entries[last].kind, ring.entries[last].window == window,
               previous.phase == record.phase, previous.button == record.button {
                previous.x = record.x
                previous.y = record.y
                previous.count += 1
                previous.dx += record.dx
                previous.dy += record.dy
                ring.entries[last].kind = .mouse(previous)
                ring.entries[last].uptimeNanos = now
                return
            }
            Self.push(InputJournalEntry(seq: ring.nextSeq, uptimeNanos: now, window: window, kind: .mouse(record)), into: &ring)
        }
    }

    // MARK: Reading

    struct Stats: Hashable, Sendable, Codable {
        var enabled: Bool
        var recordsCharacters: Bool
        var capacity: Int
        var count: Int
        /// Entries the ring dropped to make room.
        var overwritten: UInt64
        var lastSeq: UInt64
    }

    var stats: Stats {
        let (capacity, count, overwritten, next) = ring.withLock { ($0.capacity, $0.entries.count, $0.overwritten, $0.nextSeq) }
        return Stats(enabled: isEnabled, recordsCharacters: recordsCharacters, capacity: capacity, count: count,
                     overwritten: overwritten, lastSeq: next - 1)
    }

    /// The newest `limit` entries (all when nil), oldest first.
    func entries(last limit: Int? = nil) -> [InputJournalEntry] {
        ring.withLock { ring in
            let ordered = Array(ring.entries[ring.head...] + ring.entries[..<ring.head])
            guard let limit, limit < ordered.count else { return ordered }
            return Array(ordered.suffix(max(limit, 0)))
        }
    }

    func clear() {
        ring.withLock { ring in
            ring.entries.removeAll(keepingCapacity: true)
            ring.head = 0
        }
    }

    // MARK: Ring

    private static func push(_ entry: InputJournalEntry, into ring: inout Ring) {
        ring.nextSeq += 1
        if ring.entries.count < ring.capacity {
            ring.entries.append(entry)
        } else {
            ring.entries[ring.head] = entry
            ring.head = (ring.head + 1) % ring.capacity
            ring.overwritten += 1
        }
    }

    private static func lastIndex(of ring: Ring) -> Int? {
        guard !ring.entries.isEmpty else { return nil }
        guard ring.entries.count == ring.capacity else { return ring.entries.count - 1 }
        return (ring.head + ring.capacity - 1) % ring.capacity
    }
}

/// When the journal records (input-spec.md section 3).
nonisolated struct InputJournalPolicy: Hashable, Sendable {
    static let enableKey = "CMUX_NEXT_INPUT_JOURNAL"
    static let charactersKey = "CMUX_NEXT_INPUT_JOURNAL_CHARACTERS"

    var enabled: Bool
    var recordsCharacters: Bool

    /// On in debug builds and tagged (dogfood) builds, off in release
    /// builds; `CMUX_NEXT_INPUT_JOURNAL=0|1` overrides. Characters only with
    /// `CMUX_NEXT_INPUT_JOURNAL_CHARACTERS=1`, in every build.
    static func resolve(isDebugBuild: Bool, tag: String?, environment: [String: String]) -> InputJournalPolicy {
        let enabled: Bool = switch environment[enableKey] {
        case "0": false
        case "1": true
        default: isDebugBuild || tag != nil
        }
        return InputJournalPolicy(enabled: enabled, recordsCharacters: enabled && environment[charactersKey] == "1")
    }
}
