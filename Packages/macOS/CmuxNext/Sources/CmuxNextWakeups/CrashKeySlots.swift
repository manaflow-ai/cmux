import CmuxNextCompat
import CmuxNextTrace

/// The app's in-process crash keys (plans/cmux-next/chrome-parity/p10-stability.md section 3B, task 207): a
/// fixed block of 64-bit words, allocated once when the slots are made and never resized, that the action
/// pipeline and the hang monitor write with relaxed atomic stores and that the crash path and the hang
/// reporter read with relaxed loads. Writing or reading a key allocates nothing and takes no lock.
///
/// Chrome's model: `components/crash/core/common/crash_key.h` keeps each key in static storage set up before
/// the crash (`CrashKeyString<N>`), `ScopedCrashKeyString` restores the outer value at scope exit, and
/// Crashpad reads the storage at crash time without running code in the dead process. Chrome's `HangWatcher`
/// (base/threading/hang_watcher.cc) names the hung threads in the dump it takes. cmux keeps numbers only:
/// every value is an index, a code, an epoch or a thread port, never a person's text, so a record of the keys
/// is already scrubbed.
///
/// The composition root makes one and passes it to the action timing (``CrashKeySlots/Key/actionID``),
/// the main-thread watchdog's hang monitor (hung threads) and the crash path (`CrashKeys` in
/// CmuxNextCrashReporting). Tests make their own.
///
/// ```swift
/// let keys = CrashKeySlots()
/// keys.withKey(.actionID, CrashKeySlots.stableKey("workspace.new")) { run() } // the outer value is back after `run`
/// ```
public final class CrashKeySlots: Sendable {
    /// A catalog name (an action id) as a key value: FNV-1a 64 of its UTF-8 bytes, never 0. Walks the string's
    /// UTF-8 view, so a native string (every action id is a literal) costs no allocation.
    public static func stableKey(_ name: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash == 0 ? 1 : hash
    }

    /// One single-word key. The raw value is the key's word in the block: fixed, so a reader that has only
    /// the block's address (``read(wordsAt:)``) decodes it.
    public enum Key: Int, Sendable, CaseIterable {
        /// The running action's id as ``stableKey(_:)`` of its raw value (the same number in every build and
        /// launch, so a report maps it back to the catalog), or 0 outside action runs.
        case actionID = 0
        /// The focused pane's kind (``PaneKind``'s raw value), 0 when none is focused.
        case paneKind = 1
        /// The Chromium runtime's state (``CEFState``'s raw value).
        case cefState = 2
        /// The daemon connection's epoch (it moves on each reconnect), 0 before the first connection.
        case daemonEpoch = 3

        /// The key's name in a crash record and a crash report's tags (`crash_key.<name>`).
        public var name: StaticString {
            switch self {
            case .actionID: "action_id"
            case .paneKind: "pane_kind"
            case .cefState: "cef_state"
            case .daemonEpoch: "daemon_epoch"
            }
        }
    }

    /// The kind of the focused pane, as ``Key/paneKind`` stores it. Fixed values: a record written by an older
    /// build decodes.
    public enum PaneKind: UInt64, Sendable, CaseIterable {
        case terminal = 1
        case browser = 2
        case agent = 3
        case markdown = 4
        case diff = 5
        case files = 6
        /// A pane kind this list does not name.
        case other = 7

        /// The kind's name in a crash report's tags.
        public var name: StaticString {
            switch self {
            case .terminal: "terminal"
            case .browser: "browser"
            case .agent: "agent"
            case .markdown: "markdown"
            case .diff: "diff"
            case .files: "files"
            case .other: "other"
            }
        }
    }

    /// The Chromium runtime's state, as ``Key/cefState`` stores it (0: Chromium never started). Fixed values.
    public enum CEFState: UInt64, Sendable, CaseIterable {
        case initializing = 1
        case running = 2
        /// The message pump runs on this thread now (`CefDoMessageLoopWork`).
        case inPump = 3
        case shuttingDown = 4
        case failed = 5

        /// The state's name in a crash report's tags.
        public var name: StaticString {
            switch self {
            case .initializing: "initializing"
            case .running: "running"
            case .inPump: "in_pump"
            case .shuttingDown: "shutting_down"
            case .failed: "failed"
            }
        }
    }

    /// A thread the hang monitor reported hung whose scope was still open when the monitor last looked.
    public struct HungThread: Sendable, Hashable {
        /// The thread's Mach port (`pthread_mach_thread_np`); never 0.
        public var port: UInt32
        /// What the thread runs (`HangWatch.ThreadKind`'s raw value; 0 when the registration has none).
        public var kind: UInt8

        public init(port: UInt32, kind: UInt8) {
            self.port = port
            self.kind = kind
        }

        /// The entry's word: the kind in bits 32-39, the port in the low 32 bits. 0 is an empty entry.
        var packed: UInt64 { UInt64(kind) << 32 | UInt64(port) }

        init?(packed: UInt64) {
            guard packed & 0xFFFF_FFFF != 0 else { return nil }
            self.init(port: UInt32(truncatingIfNeeded: packed), kind: UInt8(truncatingIfNeeded: packed >> 32))
        }
    }

    /// The keys' values at one moment: a fixed-size value (no array), so taking one allocates nothing.
    public struct Snapshot: Sendable, Equatable {
        public var actionID: UInt64 = 0
        public var paneKind: UInt64 = 0
        public var cefState: UInt64 = 0
        public var daemonEpoch: UInt64 = 0
        /// The hung-thread entries' packed words, in entry order (0: empty).
        var hung: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0)

        public init() {}

        /// The value of `key`.
        public subscript(key: Key) -> UInt64 {
            switch key {
            case .actionID: actionID
            case .paneKind: paneKind
            case .cefState: cefState
            case .daemonEpoch: daemonEpoch
            }
        }

        /// The hung-thread entry at `index` (`0..<hungThreadCapacity`), nil when it is empty.
        public func hungThread(at index: Int) -> HungThread? {
            guard index >= 0, index < CrashKeySlots.hungThreadCapacity else { return nil }
            return withUnsafeBytes(of: hung) { HungThread(packed: $0.load(fromByteOffset: index * 8, as: UInt64.self)) }
        }

        /// Sets the hung-thread entry at `index` (`0..<hungThreadCapacity`; nil empties it): a snapshot read back
        /// from a crash record.
        public mutating func setHungThread(_ thread: HungThread?, at index: Int) {
            guard index >= 0, index < CrashKeySlots.hungThreadCapacity else { return }
            let packed = thread?.packed ?? 0
            withUnsafeMutableBytes(of: &hung) { $0.storeBytes(of: packed, toByteOffset: index * 8, as: UInt64.self) }
        }

        /// How many hung-thread entries are set.
        public var hungThreadCount: Int {
            (0..<CrashKeySlots.hungThreadCapacity).reduce(0) { $0 + (hungThread(at: $1) == nil ? 0 : 1) }
        }

        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            guard lhs.actionID == rhs.actionID, lhs.paneKind == rhs.paneKind, lhs.cefState == rhs.cefState,
                  lhs.daemonEpoch == rhs.daemonEpoch else { return false }
            return (0..<CrashKeySlots.hungThreadCapacity).allSatisfy { lhs.hungThread(at: $0) == rhs.hungThread(at: $0) }
        }

        /// The keys as a report's tags (`crash_key.<name>`): the action id's key in hex, the pane kind's,
        /// Chromium state's and hung threads' catalog names, the daemon epoch. Never a thread port (it means
        /// nothing outside the process) and never text from the person. Keys at 0 are left out. Allocates: for
        /// a report, never for the crash path.
        public var tags: [String: String] {
            var tags: [String: String] = [:]
            if actionID != 0 { tags["crash_key.action_id"] = String(actionID, radix: 16) }
            if paneKind != 0 { tags["crash_key.pane_kind"] = PaneKind(rawValue: paneKind).map { "\($0.name)" } ?? "unknown" }
            if cefState != 0 { tags["crash_key.cef_state"] = CEFState(rawValue: cefState).map { "\($0.name)" } ?? "unknown" }
            if daemonEpoch != 0 { tags["crash_key.daemon_epoch"] = String(daemonEpoch) }
            let kinds = (0..<CrashKeySlots.hungThreadCapacity).compactMap { hungThread(at: $0) }.map { thread in
                HangWatch.ThreadKind(rawValue: thread.kind).map { "\($0)" } ?? "unknown"
            }
            if !kinds.isEmpty {
                tags["crash_key.hung_threads"] = String(kinds.count)
                tags["crash_key.hung_thread_kinds"] = kinds.joined(separator: ",")
            }
            return tags
        }
    }

    /// The hung-thread entries the block holds; a ninth concurrent hang is not named (the count of reported
    /// hangs is in the hang log). Matches the 8-tuple of ``Snapshot``. Computed, not stored: the crash path
    /// reads it, and a stored static would initialize lazily there.
    public static var hungThreadCapacity: Int { 8 }
    /// The word of the first hung-thread entry: one past the last ``Key``.
    static var firstHungWord: Int { 4 }
    /// The block's size in words: the keys, then the hung-thread entries.
    public static var wordCount: Int { firstHungWord + hungThreadCapacity }

    /// The block's address (8-byte aligned, ``wordCount`` words), owned by these slots: allocated and zeroed
    /// in `init`, freed in `deinit`. Kept as an integer so the class is `Sendable` with no unchecked claim; every
    /// access goes through ``AtomicPointerSlot``.
    public let wordsAddress: UInt

    /// Empty slots: every key 0, no hung thread.
    public init() {
        let words = UnsafeMutablePointer<UInt64>.allocate(capacity: Self.wordCount)
        words.initialize(repeating: 0, count: Self.wordCount)
        wordsAddress = UInt(bitPattern: words)
    }

    deinit {
        UnsafeMutablePointer<UInt64>(bitPattern: wordsAddress)?.deallocate()
    }

    // MARK: keys

    /// Stores `value` in `key` (one relaxed store).
    @inline(__always)
    public func set(_ key: Key, _ value: UInt64) {
        Self.slot(wordsAddress, key.rawValue).store(value, ordering: .relaxed)
    }

    /// The value `key` holds now (0 when never set).
    @inline(__always)
    public func value(_ key: Key) -> UInt64 {
        Self.slot(wordsAddress, key.rawValue).load(ordering: .relaxed)
    }

    /// Runs `body` with `key` set to `value`, then puts the value it replaced back (Chrome's
    /// `ScopedCrashKeyString`): a nested action run puts the outer run's id back when it returns. The key belongs
    /// to the thread that runs `body`; the action id is set on the main thread only.
    @inline(__always)
    public func withKey<T>(_ key: Key, _ value: UInt64, _ body: () throws -> T) rethrows -> T {
        let slot = Self.slot(wordsAddress, key.rawValue)
        let outer = slot.exchange(value, ordering: .relaxed)
        defer { slot.store(outer, ordering: .relaxed) }
        return try body()
    }

    // MARK: hung threads

    /// Names `thread` among the hung threads (the hang monitor, when it reports a scope past its deadline).
    /// The hang monitor's thread is the one writer of the entries; readers on any thread see each entry whole.
    ///
    /// - Returns: false when every entry is taken (the thread is not named) or the port is 0.
    @discardableResult
    public func noteHung(_ thread: HungThread) -> Bool {
        guard thread.port != 0 else { return false }
        for index in 0..<Self.hungThreadCapacity {
            let slot = hungSlot(index)
            let current = slot.load(ordering: .relaxed)
            if HungThread(packed: current)?.port == thread.port {
                slot.store(thread.packed, ordering: .relaxed)
                return true
            }
        }
        for index in 0..<Self.hungThreadCapacity {
            if hungSlot(index).compareExchange(expected: 0, desired: thread.packed, ordering: .relaxed).exchanged { return true }
        }
        return false
    }

    /// Takes the thread on `port` off the hung threads (its scope ended).
    public func clearHung(port: UInt32) {
        guard port != 0 else { return }
        for index in 0..<Self.hungThreadCapacity {
            let slot = hungSlot(index)
            let current = slot.load(ordering: .relaxed)
            if HungThread(packed: current)?.port == port {
                _ = slot.compareExchange(expected: current, desired: 0, ordering: .relaxed)
            }
        }
    }

    // MARK: reading

    /// Every key and hung-thread entry now, with relaxed loads: no allocation, no lock.
    public func snapshot() -> Snapshot {
        Self.read(wordsAt: wordsAddress)
    }

    /// The keys of the block at `address` (``wordsAddress`` of live slots), for a reader that holds only the
    /// address: the crash path, which cannot retain an object. Async-signal-safe.
    public static func read(wordsAt address: UInt) -> Snapshot {
        var snapshot = Snapshot()
        guard address != 0 else { return snapshot }
        snapshot.actionID = slot(address, Key.actionID.rawValue).load(ordering: .relaxed)
        snapshot.paneKind = slot(address, Key.paneKind.rawValue).load(ordering: .relaxed)
        snapshot.cefState = slot(address, Key.cefState.rawValue).load(ordering: .relaxed)
        snapshot.daemonEpoch = slot(address, Key.daemonEpoch.rawValue).load(ordering: .relaxed)
        let first = firstHungWord
        snapshot.hung = (slot(address, first).load(ordering: .relaxed), slot(address, first + 1).load(ordering: .relaxed),
                         slot(address, first + 2).load(ordering: .relaxed), slot(address, first + 3).load(ordering: .relaxed),
                         slot(address, first + 4).load(ordering: .relaxed), slot(address, first + 5).load(ordering: .relaxed),
                         slot(address, first + 6).load(ordering: .relaxed), slot(address, first + 7).load(ordering: .relaxed))
        return snapshot
    }

    @inline(__always)
    private func hungSlot(_ index: Int) -> AtomicPointerSlot {
        Self.slot(wordsAddress, Self.firstHungWord + index)
    }

    @inline(__always)
    private static func slot(_ address: UInt, _ word: Int) -> AtomicPointerSlot {
        // The block is `wordCount` words from `init`; `word` is a key's raw value or a hung entry below the capacity.
        AtomicPointerSlot(UnsafeMutablePointer<UInt64>(bitPattern: address).unsafelyUnwrapped + word)
    }
}
