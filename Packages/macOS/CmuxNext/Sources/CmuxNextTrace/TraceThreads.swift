import CmuxNextCompat

/// The ring's thread table (plans/cmux-next/trace.md, "Release trace ring v1", Thread table): the reader of
/// its entries and the name of the thread behind each chunk. The table lives in the ring itself, in whole
/// 16 KiB pages of 256 entries taken in index order (a process with few threads dirties one page of the
/// file), so a crashed process's file still names its threads. A writer registers at its first record in a
/// ring (TraceRing.swift):
/// a fresh entry while there is one, else an exited entry taken again with the next generation; past both it
/// writes thread `0xFFFFFFFF` and counts `thread_overflow`. Its TLS destructor marks the entry exited.
/// Perfetto names each writer's thread once per sequence with a `ThreadDescriptor` (tid and name,
/// `protos/perfetto/trace/track_event/thread_descriptor.proto`); here the entry and its generation do that.
extension TraceRing {
    /// One live or exited thread-table entry.
    public struct ThreadEntry: Sendable, Equatable {
        /// Whether the entry's thread still runs.
        public enum State: UInt32, Sendable {
            /// Registered and not exited.
            case live = 2
            /// Its thread exited (the TLS destructor); a later thread may take the entry.
            case exited = 3
        }

        /// The entry index chunks name.
        public let index: UInt32
        /// Live or exited.
        public let state: State
        /// 0 for a fresh entry, + 1 each time a thread took it again after an exit.
        public let generation: UInt32
        /// `pthread_threadid_np` of the thread.
        public let tid: UInt64
        /// Its `qos_class_t` at registration.
        public let qos: UInt8
        /// `pthread_getname_np` at registration (cut at 46 bytes); empty when unnamed.
        public let name: String
    }
}

extension TraceRingStorage {
    /// The live and exited entries below `thread_cursor`, each read state and generation, fields, then the
    /// first word again (acquire), and kept only when both reads agree (trace.md "Thread table").
    func threadEntries() -> [TraceRing.ThreadEntry] {
        let cursor = Int(word(TraceRingOffsets.threadWord).load(ordering: .acquiring) >> 32)
        var entries: [TraceRing.ThreadEntry] = []
        for index in 0 ..< min(cursor, layout.threadCapacity) {
            let entry = layout.threadEntry(index)
            let first = word(entry).load(ordering: .acquiring)
            guard let state = TraceRing.ThreadEntry.State(rawValue: UInt32(truncatingIfNeeded: first)) else { continue }
            let tid = word(entry + TraceRingOffsets.threadTid).load(ordering: .acquiring)
            // qos at byte 16, name_len at 17, then at most 46 bytes of name: six words.
            let info = bytes(at: entry + TraceRingOffsets.threadInfoWord, words: 6)
            guard word(entry).load(ordering: .relaxed) == first else { continue }
            let length = min(Int(info[1]), 46)
            entries.append(TraceRing.ThreadEntry(
                index: UInt32(index), state: state, generation: UInt32(truncatingIfNeeded: first >> 32), tid: tid,
                qos: info[0], name: String(decoding: info[2 ..< 2 + length], as: UTF8.self)
            ))
        }
        return entries
    }
}

extension TraceRing.Image {
    /// The entry of the thread that wrote `record`: nil when its chunk names a full table, or an earlier
    /// occupant of an entry another thread took since (the generations differ).
    public func thread(of record: TraceRecord) -> TraceRing.ThreadEntry? {
        guard let entry = threadsByIndex[record.threadIndex], entry.generation == record.threadGeneration else { return nil }
        return entry
    }

    /// The writer of `record` as a trace export shows it: its thread name, `thread <index>` for an unnamed
    /// thread, `thread <index> (generation <g>)` for an earlier occupant of a reused entry, and
    /// `thread table full` for a writer that found no entry.
    public func threadLabel(of record: TraceRecord) -> String {
        if record.threadIndex == TraceRing.noThread { return "thread table full" }
        guard let entry = thread(of: record) else {
            return "thread \(record.threadIndex) (generation \(record.threadGeneration))"
        }
        return entry.name.isEmpty ? "thread \(entry.index)" : entry.name
    }
}
