internal import CmuxSafeConcurrencyAtomics

/// One failed ``Invariant/notFatalUntil(_:_:build:in:fileID:line:)`` or
/// ``Invariant/dumpWillBeCheck(_:_:in:fileID:line:)``: the first failure of its site in this launch.
public struct InvariantEvent: Sendable {
    /// Which call failed.
    public enum Kind: Sendable, Equatable {
        /// ``Invariant/notFatalUntil(_:_:build:in:fileID:line:)``: it traps from build `build` on.
        case notFatalUntil(build: UInt64)
        /// ``Invariant/dumpWillBeCheck(_:_:in:fileID:line:)``: it never traps.
        case dumpWillBeCheck
    }

    public let kind: Kind
    /// The invariant's name at the call (`"tab-in-its-workspace"`).
    public let id: StaticString
    public let fileID: StaticString
    public let line: UInt

    /// `fileID:line`.
    public var site: String { "\(fileID):\(line)" }

    /// One line for a log or a report title: the name and the site.
    public var message: String { "invariant \(id) failed at \(site)" }

    public init(kind: Kind, id: StaticString, fileID: StaticString, line: UInt) {
        self.kind = kind
        self.id = id
        self.fileID = fileID
        self.line = line
    }
}

/// Where a process's invariant events go: the crash reporter's background lane in the app
/// (CmuxNextCrashReporting's `InvariantSink`), a recorder in tests.
public protocol InvariantEventSink: Sendable {
    /// Takes `event` on the thread of the failed call, inside the caller's turn. Hand it off and return: no
    /// I/O, no lock that can wait, no report sent here.
    func deliver(_ event: InvariantEvent)
}

/// The one reviewed way for internal invariants to stop the process, after Chromium's three tiers
/// (base/check.h, base/not_fatal_until.h, docs/checks.md):
///
/// - ``check(_:_:fileID:line:)``, Chrome's `CHECK`: traps in every build when the condition is false. Only where
///   going on would corrupt shared or persisted state; each call site needs a `swift.invariant_check` entry with
///   its reason in scripts/cmux-next/crash-allowlist.json.
/// - ``notFatalUntil(_:_:build:in:fileID:line:)``, Chrome's `CHECK(cond, base::NotFatalUntil::M<n>)`: reports the
///   site's first failure of the launch and goes on while the running build is below `build`, then traps. Only
///   where the caller has a real way to recover.
/// - ``dumpWillBeCheck(_:_:in:fileID:line:)``, Chrome's `DUMP_WILL_BE_CHECK`: reports and goes on in every
///   build. Rare; each site needs a `swift.dump_will_be_check` allowlist entry that names the code that recovers.
///
/// Input from outside the process (a file, a peer frame, a decoded message) never goes here: it gets a typed
/// error at its boundary.
///
/// A report costs the caller one hash and one atomic claim of the site in a fixed table (so a site reports once
/// per launch, as Chrome's `DumpWillBeCheck` dedupes by location), then one hand-off to the installed
/// ``InvariantEventSink``. No lock, no allocation in the table, no I/O. The composition root installs the
/// process's sink and running build once at launch (``install(build:sink:)`` on ``process``), as Chrome's crash
/// client sets `base::debug::SetDumpWithoutCrashingFunction` (base/debug/dump_without_crashing.cc). Until then,
/// and in a process that installs none (a package's tests, the iOS app today), the running build is unknown:
/// ``notFatalUntil(_:_:build:in:fileID:line:)`` never traps, and a failure is only claimed and counted in
/// ``undeliveredCount``.
///
/// ```swift
/// Invariant.check(index < rows.count, "row-index-in-model")              // traps; allowlisted
/// Invariant.notFatalUntil(tab.workspace === self, "tab-in-its-workspace", build: 19_500_000_001)
/// guard tab.workspace === self else { return showError(.tabMoved) }       // the recovery
/// Invariant.dumpWillBeCheck(cache.isCoherent, "cache-coherent")           // allowlisted with its handler
/// guard cache.isCoherent else { return cache.rebuild() }
/// ```
@safe
public final class Invariant: @unchecked Sendable { // crash-allow: every word of `sites` and `words` is reached only through hardware atomic operations, and the installation `words[0]` names is retained by the invariant until its deinit and never written after the one compare-exchange that publishes it
    /// The process's invariant state, which the static calls use by default; its sink is installed by the
    /// composition root.
    // singleton-allow: Invariant.check / notFatalUntil / dumpWillBeCheck are free-standing calls any package makes on any thread, before any composition root exists and inside code that has no instance to take it through; Chrome's CHECK reaches the process's dump function the same way (base/debug/dump_without_crashing.cc).
    // lint:allow singleton: the process invariant table, the same exception as BlockingCallHookSlot.process.
    public static let process = Invariant()

    /// Sites one invariant table holds by default: more distinct failing sites than one launch should ever see.
    public static let defaultCapacity = 1024

    /// The number of site slots (a power of two).
    public let capacity: Int
    /// The claimed site hashes; 0 is a free slot.
    private let sites: UnsafeMutablePointer<UInt64>
    /// [0]: the installation's address (0 before ``install(build:sink:)``); [1]: ``undeliveredCount``;
    /// [2]: ``droppedCount``.
    private let words: UnsafeMutablePointer<UInt64>

    /// Makes an invariant table with at least `capacity` site slots (8 bytes a slot, allocated now). Tests make
    /// their own; the process uses ``process``.
    public init(capacity: Int = Invariant.defaultCapacity) {
        var slots = 1
        while slots < capacity { slots <<= 1 }
        let sites = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: slots)
        unsafe sites.initialize(repeating: 0, count: slots)
        let words = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: 3)
        unsafe words.initialize(repeating: 0, count: 3)
        self.capacity = slots
        unsafe self.sites = sites
        unsafe self.words = words
    }

    deinit {
        if let installed = installation() {
            // SAFETY: the +1 that install(build:sink:) took; nothing reads the installation after deinit begins.
            unsafe Unmanaged.passUnretained(installed).release()
        }
        unsafe sites.deinitialize(count: capacity)
        unsafe sites.deallocate()
        unsafe words.deinitialize(count: 3)
        unsafe words.deallocate()
    }

    // MARK: - The three tiers

    /// Traps, in every build, when `condition` is false. Each call site needs a `swift.invariant_check` entry
    /// with its reason in scripts/cmux-next/crash-allowlist.json.
    @inlinable
    public static func check(_ condition: @autoclosure () -> Bool, _ id: StaticString,
                             fileID: StaticString = #fileID, line: UInt = #line) {
        if !condition() { trap(id, fileID: fileID, line: line) }
    }

    /// When `condition` is false: traps from build `build` on; below it (or with no running build installed),
    /// reports the site's first failure of the launch to the installed sink and returns, so the caller recovers.
    ///
    /// - Parameters:
    ///   - build: The first build (`CFBundleVersion`) in which a failure traps. Only ever raised with a reason.
    ///   - invariant: The table and sink; ``process`` unless a test passes its own.
    /// - Returns: Whether this call was its site's first failure of the launch (the one that reported).
    @inlinable @discardableResult
    public static func notFatalUntil(_ condition: @autoclosure () -> Bool, _ id: StaticString, build: UInt64,
                                     in invariant: Invariant = .process,
                                     fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        if condition() { return false }
        return invariant.failed(.notFatalUntil(build: build), id, fileID: fileID, line: line)
    }

    /// When `condition` is false, reports the site's first failure of the launch to the installed sink and
    /// returns; never traps. Each call site needs a `swift.dump_will_be_check` allowlist entry that names the code
    /// that recovers.
    ///
    /// - Returns: Whether this call was its site's first failure of the launch (the one that reported).
    @inlinable @discardableResult
    public static func dumpWillBeCheck(_ condition: @autoclosure () -> Bool, _ id: StaticString,
                                       in invariant: Invariant = .process,
                                       fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        if condition() { return false }
        return invariant.failed(.dumpWillBeCheck, id, fileID: fileID, line: line)
    }

    /// Whether a ``notFatalUntil(_:_:build:in:fileID:line:)`` failure traps: only once the running build is known
    /// and at or past the build the call names.
    public static func traps(fatalFrom build: UInt64, runningBuild: UInt64?) -> Bool {
        guard let runningBuild else { return false }
        return runningBuild >= build
    }

    // MARK: - Installation

    /// Installs the process's running build and sink when none is installed. Call once, from the composition
    /// root, at launch.
    ///
    /// - Parameters:
    ///   - build: The running build (`CFBundleVersion` as a number); nil when it is not a number, which never traps.
    ///   - sink: Where events go (it applies consent: a sink with reports off drops them).
    /// - Returns: Whether this call installed them; false when an installation is already there, which stays.
    @discardableResult
    public func install(build: UInt64?, sink: any InvariantEventSink) -> Bool {
        let installation = Installation(build: build, sink: sink)
        let retained = unsafe Unmanaged.passRetained(installation)
        let address = unsafe UInt64(UInt(bitPattern: retained.toOpaque()))
        // SAFETY: `words` holds three words for the table's lifetime.
        guard unsafe cmux_safe_atomic_compare_exchange(words, 0, address) else {
            unsafe retained.release()
            return false
        }
        return true
    }

    /// The installed running build; nil before ``install(build:sink:)`` or when it was not a number.
    public var runningBuild: UInt64? {
        installation()?.build
    }

    /// Failures claimed while no sink was installed: their sites will not report again this launch.
    public var undeliveredCount: UInt64 {
        // SAFETY: as in install(build:sink:).
        unsafe cmux_safe_atomic_load_relaxed(words + 1)
    }

    /// Failures not reported because every site slot was taken (more than ``capacity`` failing sites).
    public var droppedCount: UInt64 {
        // SAFETY: as in install(build:sink:).
        unsafe cmux_safe_atomic_load_relaxed(words + 2)
    }

    // MARK: - The failure path

    /// What ``install(build:sink:)`` publishes.
    final class Installation: Sendable {
        let build: UInt64?
        let sink: any InvariantEventSink

        init(build: UInt64?, sink: any InvariantEventSink) {
            self.build = build
            self.sink = sink
        }
    }

    /// The installation, or nil before ``install(build:sink:)``.
    private func installation() -> Installation? {
        // SAFETY: as in install(build:sink:); the acquire sees the installation's initialization.
        let address = unsafe cmux_safe_atomic_load_acquire(words)
        guard let opaque = unsafe UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: address)) else { return nil }
        // SAFETY: a nonzero word is the address of the installation install(build:sink:) retained; it is released
        // only in deinit, which cannot run while a method of this table runs.
        return unsafe Unmanaged<Installation>.fromOpaque(opaque).takeUnretainedValue()
    }

    /// A failed report-tier call: traps when its build is reached, else claims the site and hands the event to
    /// the sink. Returns whether this call claimed the site.
    @usableFromInline
    func failed(_ kind: InvariantEvent.Kind, _ id: StaticString, fileID: StaticString, line: UInt) -> Bool {
        let installed = installation()
        if case .notFatalUntil(let build) = kind, Self.traps(fatalFrom: build, runningBuild: installed?.build) {
            Self.trap(id, fileID: fileID, line: line)
        }
        guard claim(Self.siteHash(id, fileID: fileID, line: line)) else { return false }
        guard let installed else {
            // SAFETY: as in install(build:sink:).
            _ = unsafe cmux_safe_atomic_fetch_add_relaxed(words + 1, 1)
            return true
        }
        installed.sink.deliver(InvariantEvent(kind: kind, id: id, fileID: fileID, line: line))
        return true
    }

    /// Claims the slot of `hash` (open addressing, linear probing): true for the first claim, false when the site
    /// already reported or every slot is taken (counted in ``droppedCount``). Lock-free: loads and one
    /// compare-exchange per probed slot.
    private func claim(_ hash: UInt64) -> Bool {
        let mask = capacity - 1
        var index = Int(truncatingIfNeeded: hash) & mask
        for _ in 0 ..< capacity {
            // SAFETY: index <= mask < capacity, the words `sites` holds for the table's lifetime.
            let slot = unsafe sites + index
            let seen = unsafe cmux_safe_atomic_load_acquire(slot)
            if seen == hash { return false }
            if seen == 0 {
                if unsafe cmux_safe_atomic_compare_exchange(slot, 0, hash) { return true }
                // Another failure took the slot first: the same site (it reported), or another one (probe on).
                if unsafe cmux_safe_atomic_load_acquire(slot) == hash { return false }
            }
            index = (index + 1) & mask
        }
        // SAFETY: as in install(build:sink:).
        _ = unsafe cmux_safe_atomic_fetch_add_relaxed(words + 2, 1)
        return false
    }

    /// The site's 64-bit FNV-1a hash of its name, file and line; never 0 (a free slot). Reads the literals in
    /// place: no String is made.
    static func siteHash(_ id: StaticString, fileID: StaticString, line: UInt) -> UInt64 {
        var hash = mixing(id, into: 0xcbf2_9ce4_8422_2325)
        hash = mixing(byte: 0, into: hash)
        hash = mixing(fileID, into: hash)
        hash = mixing(byte: 0, into: hash)
        var rest = UInt64(line)
        for _ in 0 ..< 8 {
            hash = mixing(byte: UInt8(truncatingIfNeeded: rest), into: hash)
            rest >>= 8
        }
        return hash == 0 ? 1 : hash
    }

    private static func mixing(_ text: StaticString, into hash: UInt64) -> UInt64 {
        // SAFETY: `bytes` is the literal's UTF-8 storage, valid for `count` bytes for the whole closure; only read.
        unsafe text.withUTF8Buffer { bytes in
            unsafe bytes.reduce(hash) { hash, byte in mixing(byte: byte, into: hash) }
        }
    }

    private static func mixing(byte: UInt8, into hash: UInt64) -> UInt64 {
        (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    }

    /// Stops the process: the one trap of the three tiers (crash-allowlist.json, swift.fatal_error).
    @usableFromInline
    static func trap(_ id: StaticString, fileID: StaticString, line: UInt) -> Never {
        fatalError("invariant \(id) failed at \(fileID):\(line)")
    }
}
