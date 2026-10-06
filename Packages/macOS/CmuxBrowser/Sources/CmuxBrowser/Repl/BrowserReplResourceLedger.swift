import Foundation

/// What a REPL session holds on someone's behalf: memory, work, slots and
/// disk. Every holder reserves from the session's
/// ``BrowserReplResourceLedger`` before it holds and releases when it lets
/// go, so the session's limits live in one table
/// (``BrowserReplResourceLimits``) and are checked in one place.
public enum BrowserReplResource: String, CaseIterable, Sendable {
    /// Cells waiting for the running one.
    case waitingCells
    /// The source those cells hold.
    case waitingCellSourceBytes
    /// What parsing and compiling the running cell's source holds, reserved
    /// before the runtime parses it (``BrowserReplSession/parseBytesPerSourceByte``
    /// for each byte of source) and released when the cell ends.
    case runningCellParseBytes
    /// Output the running cell keeps in memory for its caller.
    case retainedOutputBytes
    /// Output the running cell wrote to its spill file.
    case spilledOutputBytes
    /// Driver calls waiting for a slot.
    case queuedDriverCalls
    /// Driver calls running, until the runtime has their result.
    case runningDriverCalls
    /// Parameters of the driver calls and fetch requests waiting or running.
    case requestBytes
    /// Native input events the browser calls running will send (an
    /// `input.drag` sends one for each step of its path), reserved before
    /// the call waits or runs.
    case inputEvents
    /// Driver results (and errors) the runtime has not taken yet.
    case driverResultBytes
    /// The arguments of the synchronous host call running (`fs`, `secrets`,
    /// `policy`), reserved before they are parsed or decoded.
    case hostCallBytes
    /// Fetches waiting for a slot.
    case queuedFetches
    /// Fetches waiting for their response's headers.
    case requestPhaseFetches
    /// Fetches open: waiting for headers, receiving a body, or holding one
    /// the runtime has not taken yet.
    case openFetches
    /// Response bodies the session's fetches hold.
    case fetchBodyBytes
    /// Page events queued for the session's thread or held back.
    case queuedEvents
    /// The bytes those events hold, masked.
    case queuedEventBytes
    /// Page events held back while callbacks outside a cell are in debt.
    case heldEvents
    /// Timers scheduled, or fired with their callback not yet run.
    case pendingTimers
    /// The session's JavaScript heap (JavaScriptCore's own measure of its
    /// objects and the strings and buffers they hold), as last measured:
    /// as each cell ends, and after other runs of the session's JavaScript
    /// at most 5% of the thread's time. JavaScriptCore has no heap limit of
    /// its own, so a measure past this limit, after a full garbage
    /// collection, ends the session (``isMeasured``).
    case scriptHeapBytes
    /// The paths an fs call names (`path`, `from`, `to`), while it runs.
    /// One past its per-item limit (`PATH_MAX`, as the system takes a
    /// path) is refused before any work, with `ENAMETOOLONG`.
    case fsPathBytes
    /// Bytes the session's fs (and its spill files and file chooser
    /// answers) wrote over its life.
    case fileBytesWritten
    /// Entries the session's fs created, made, renamed or removed over its life.
    case fileEntryChanges
    /// Distinct files the session's `secrets.load` protected from every
    /// tab over its life (``BrowserReplSecretSources``); the protection
    /// outlasts the session, so a reset does not give them back.
    case secretSourceFiles
    /// Distinct sets of domains the session typed a secret into or asked
    /// the sign-in sheet for over its life, each kept so the domain policy
    /// never reaches past it (``BrowserReplBoundary``); a set is counted
    /// once however its domains are ordered or repeated.
    case typedDomainSets
    /// Everything the session holds in memory together: the sum of the
    /// resources that are memory (``isMemory``), each also within its own limit.
    case sessionMemoryBytes

    /// How a limit counts.
    public enum Scope: Sendable {
        /// What is held now; released when the holder lets go.
        case atOnce
        /// What the running cell holds; released when the cell ends.
        case perCell
        /// Everything over the session's life; never released.
        case lifetime
    }

    public var scope: Scope {
        switch self {
        case .retainedOutputBytes, .spilledOutputBytes: .perCell
        case .fileBytesWritten, .fileEntryChanges, .secretSourceFiles, .typedDomainSets: .lifetime
        default: .atOnce
        }
    }

    /// Whether the amounts are bytes (else items).
    public var isBytes: Bool {
        switch self {
        case .waitingCellSourceBytes, .runningCellParseBytes, .retainedOutputBytes, .spilledOutputBytes, .requestBytes,
             .driverResultBytes, .hostCallBytes, .fetchBodyBytes, .queuedEventBytes, .scriptHeapBytes, .fsPathBytes,
             .fileBytesWritten, .sessionMemoryBytes:
            true
        default:
            false
        }
    }

    /// Whether what it holds is the session's memory, and so counts toward
    /// ``sessionMemoryBytes`` too.
    public var isMemory: Bool {
        switch self {
        case .waitingCellSourceBytes, .runningCellParseBytes, .retainedOutputBytes, .requestBytes, .driverResultBytes,
             .hostCallBytes, .fetchBodyBytes, .queuedEventBytes, .scriptHeapBytes:
            true
        default:
            false
        }
    }

    /// Whether it is measured after the fact rather than reserved before:
    /// only its own limit refuses it, and it counts toward
    /// ``sessionMemoryBytes`` without that limit refusing it, so a heap
    /// that grew leaves less for the other holders, and a session whose
    /// other holders are full does not end because its heap was measured.
    public var isMeasured: Bool {
        self == .scriptHeapBytes
    }

    /// What the limit counts, as an error names it.
    public var title: String {
        switch self {
        case .waitingCells: "cells waiting to run"
        case .waitingCellSourceBytes: "source of the cells waiting to run"
        case .runningCellParseBytes: "memory to parse the running cell (\(BrowserReplSession.parseBytesPerSourceByte) bytes for each byte of its source)"
        case .retainedOutputBytes: "output a cell keeps in memory"
        case .spilledOutputBytes: "output a cell spills to its file"
        case .queuedDriverCalls: "browser calls waiting for a slot"
        case .runningDriverCalls: "browser calls running"
        case .requestBytes: "parameters of the browser calls and fetches waiting or running"
        case .inputEvents: "native input events of the browser calls waiting or running"
        case .driverResultBytes: "browser call results the session's JavaScript has not taken yet"
        case .hostCallBytes: "arguments of an fs, secrets or policy call"
        case .queuedFetches: "fetches waiting for a slot"
        case .requestPhaseFetches: "fetches waiting for their response headers"
        case .openFetches: "open fetches"
        case .fetchBodyBytes: "response bodies the session's fetches hold"
        case .queuedEvents: "page events waiting for the session's thread"
        case .queuedEventBytes: "bytes of the page events waiting for the session's thread"
        case .heldEvents: "page events held back between cells"
        case .pendingTimers: "pending timers"
        case .scriptHeapBytes: "the session's JavaScript heap"
        case .fsPathBytes: "an fs path"
        case .fileBytesWritten: "bytes the session's fs writes"
        case .fileEntryChanges: "file changes (files created, directories made, entries renamed or removed)"
        case .secretSourceFiles: "files secrets.load read and protects from every tab"
        case .typedDomainSets: "distinct domain sets of the secrets and sign-in credentials the session typed"
        case .sessionMemoryBytes: "memory the session holds in all"
        }
    }

    /// What the caller can do about it.
    public var remedy: String {
        switch self {
        case .waitingCells, .waitingCellSourceBytes: "wait for them to finish"
        case .runningCellParseBytes: "split the cell, or read large data from a file"
        case .retainedOutputBytes, .spilledOutputBytes: "print less, or write it to a file"
        case .queuedDriverCalls, .runningDriverCalls, .requestBytes, .queuedFetches,
             .requestPhaseFetches, .openFetches:
            "await some before starting more"
        case .driverResultBytes: "await results before starting more calls"
        case .inputEvents: "use a shorter drag path, or await earlier drags first"
        case .hostCallBytes: "pass less at once (write a large file in parts)"
        case .fetchBodyBytes: "await some before starting more, or download large files in a tab (page.waitForEvent(\"download\"))"
        case .queuedEvents, .queuedEventBytes, .heldEvents: "let the session's thread take them"
        case .pendingTimers: "clear some first"
        case .scriptHeapBytes: "keep less in variables between cells"
        case .fsPathBytes: "use a shorter path"
        case .fileBytesWritten: "reset the session (cmux browser repl reset NAME) to write more"
        case .fileEntryChanges: "reset the session (cmux browser repl reset NAME) to make more"
        case .secretSourceFiles: "load secrets from fewer files (one file holds many), or set them with secrets.set"
        case .typedDomainSets: "type secrets on fewer domain sets, or reset the session (cmux browser repl reset NAME)"
        case .sessionMemoryBytes: "await results and let cells finish before starting more"
        }
    }
}

/// The limits of every ``BrowserReplResource``: one table, read by the
/// ledger, the session and the docs (`docs/browser-repl/README.md`,
/// "Limits"). Tests lower them; production uses ``standard``.
public struct BrowserReplResourceLimits: Sendable, Equatable {
    private var totals: [BrowserReplResource: Int]
    private var items: [BrowserReplResource: Int]

    /// The limit on `resource` held together (at once, per cell or over the
    /// session's life, by its scope).
    public subscript(_ resource: BrowserReplResource) -> Int {
        totals[resource] ?? .max
    }

    /// The limit on one reservation of `resource`, or nil.
    public func each(_ resource: BrowserReplResource) -> Int? {
        items[resource]
    }

    /// The same limits with `resource` held together at most `limit`.
    public func with(_ resource: BrowserReplResource, _ limit: Int) -> Self {
        var copy = self
        copy.totals[resource] = limit
        return copy
    }

    /// The same limits with one reservation of `resource` at most `limit`.
    public func with(_ resource: BrowserReplResource, each limit: Int?) -> Self {
        var copy = self
        copy.items[resource] = limit
        return copy
    }

    /// No limit on anything; a holder made outside a session starts here.
    public static let unbounded = BrowserReplResourceLimits(totals: [:], items: [:])

    /// The session's limits.
    public static let standard = BrowserReplResourceLimits(
        totals: [
            .waitingCells: 64,
            .waitingCellSourceBytes: 64 << 20,
            .retainedOutputBytes: 16 << 20,
            .spilledOutputBytes: 64 << 20,
            .queuedDriverCalls: 10_000,
            // The snapshot reads up to 256 frames at once (snapshot.js).
            .runningDriverCalls: 256,
            .requestBytes: 512 << 20,
            // A drag of 10,000 events takes AppKit and WebKit seconds on
            // the main actor; a session's calls wait or run at most ten.
            .inputEvents: 100_000,
            .driverResultBytes: 512 << 20,
            .queuedFetches: 256,
            .requestPhaseFetches: 16,
            .openFetches: 64,
            .fetchBodyBytes: 128 << 20,
            .queuedEvents: 10_000,
            .queuedEventBytes: 64 << 20,
            .heldEvents: 10_000,
            .pendingTimers: 10_000,
            // Counted in the session's memory below too, and kept under it
            // so results and fetch bodies still fit beside a full heap.
            .scriptHeapBytes: 384 << 20,
            .fileBytesWritten: 2 << 30,
            .fileEntryChanges: 100_000,
            // Decided 2026-10-06 (r18 e5): 512 of the app's 4,096
            // (BrowserReplSecretSources), so one session cannot fill it.
            .secretSourceFiles: 512,
            // Decided 2026-10-06 (r21): each set is kept for the session's
            // life and checked on every policy change.
            .typedDomainSets: 1_024,
            // Decided 2026-10-04 (C9): the per-holder limits above add up
            // to more, so this bounds them together.
            .sessionMemoryBytes: 512 << 20,
        ],
        items: [
            // One browser call's parameters (the fetch and readFile limit).
            .requestBytes: 64 << 20,
            .driverResultBytes: 64 << 20,
            // One drag: a path of 2,000 points.
            .inputEvents: 10_000,
            // One fs, secrets or policy call's arguments (an fs call's limit
            // is one write's in Base64, BrowserReplSession.hostCallLimit).
            .hostCallBytes: 64 << 20,
            // One fetch's response body.
            .fetchBodyBytes: 64 << 20,
            // One page event; a larger one arrives withheld.
            .queuedEventBytes: 1 << 20,
            // One writeFile, copyFile or file chooser answer.
            .fileBytesWritten: 256 << 20,
            // One fs path, as the system takes one.
            .fsPathBytes: Int(PATH_MAX),
        ]
    )

    /// `64 MiB`, `2 GiB`, `1000 bytes` or `256` (items).
    static func describe(_ amount: Int, of resource: BrowserReplResource) -> String {
        guard resource.isBytes else { return "\(amount)" }
        if amount >= 1 << 30, amount % (1 << 30) == 0 { return "\(amount >> 30) GiB" }
        if amount >= 1 << 20, amount % (1 << 20) == 0 { return "\(amount >> 20) MiB" }
        if amount >= 1 << 20 { return "\(amount >> 20) MiB" }
        return "\(amount) bytes"
    }
}

/// A reservation the ledger refused: which limit, and where the session stood.
public struct BrowserReplResourceLimitError: Error, Sendable, Equatable {
    public let resource: BrowserReplResource
    /// The limit that refused it.
    public let limit: Int
    /// Whether it was the limit on one reservation (else on what is held together).
    public let isPerItem: Bool
    /// What was held when it was refused.
    public let held: Int
    /// What the reservation asked for.
    public let requested: Int

    /// The one message form every limit uses: the limit, where the session
    /// stood, and what to do.
    public var message: String {
        let describe = { (amount: Int) in BrowserReplResourceLimits.describe(amount, of: resource) }
        if isPerItem {
            return "REPL session limit: \(resource.title) at most \(describe(limit)) each (this one is \(describe(requested))); \(resource.remedy)"
        }
        let scope = switch resource.scope {
        case .atOnce: "at once"
        case .perCell: "per cell"
        case .lifetime: "over the session's life"
        }
        return "REPL session limit: \(resource.title) at most \(describe(limit)) \(scope) (\(describe(held)) held, this needs \(describe(requested)) more); \(resource.remedy)"
    }

    /// The refusal as a driver error, after `context` (`fetch`, a method).
    public func driverError(_ context: String? = nil) -> BrowserReplDriverError {
        BrowserReplDriverError(code: "invalid", message: context.map { "\($0): \(message)" } ?? message)
    }
}

/// One REPL session's resources: what each holder reserved and has not
/// released, checked against ``BrowserReplResourceLimits``.
///
/// Every holder (cells waiting, driver calls and their parameters and
/// results, fetches and their bodies, page events, timers, output and fs
/// writes) reserves here before it holds and releases when it delivers or
/// drops. ``outstanding`` returns to empty once a session is closed and its
/// work has drained, which a test checks for every holder.
public final class BrowserReplResourceLedger: @unchecked Sendable {
    public let limits: BrowserReplResourceLimits
    private let lock = NSLock()
    private var held: [BrowserReplResource: Int] = [:]
    private var peaks: [BrowserReplResource: Int] = [:]

    public init(limits: BrowserReplResourceLimits = .standard) {
        self.limits = limits
    }

    /// Reserves `amount` of `resource`, or returns why it does not fit and
    /// reserves nothing. `each` replaces the limit on one reservation;
    /// `force` reserves regardless (a small error in place of a refused
    /// result, so the holder's accounting stays whole).
    @discardableResult
    public func reserve(
        _ amount: Int,
        of resource: BrowserReplResource,
        each: Int? = nil,
        force: Bool = false
    ) -> BrowserReplResourceLimitError? {
        lock.withLock { reserveLocked(amount, of: resource, replacing: 0, each: each, force: force) }
    }

    /// Replaces a reservation of `old` with one of `new` (a result that
    /// masking grew), or returns why `new` does not fit and keeps `old`.
    /// `each` replaces the limit on one reservation, as for ``reserve(_:of:each:force:)``.
    @discardableResult
    public func resize(
        _ resource: BrowserReplResource,
        from old: Int,
        to new: Int,
        each: Int? = nil,
        force: Bool = false
    ) -> BrowserReplResourceLimitError? {
        lock.withLock { reserveLocked(new, of: resource, replacing: old, each: each, force: force) }
    }

    /// Whether `amount` of `resource` would fit now; reserves nothing.
    public func fits(_ amount: Int, of resource: BrowserReplResource) -> Bool {
        lock.withLock { amount <= limits[resource] - (held[resource] ?? 0) }
    }

    /// Releases `amount` of `resource`. Lifetime resources are never released.
    public func release(_ amount: Int, of resource: BrowserReplResource) {
        guard amount > 0, resource.scope != .lifetime else { return }
        lock.withLock {
            assert((held[resource] ?? 0) >= amount, "\(resource) released more than it reserved")
            addLocked(-amount, to: resource)
            if resource.isMemory { addLocked(-amount, to: .sessionMemoryBytes) }
        }
    }

    /// Releases everything held of `resources` (what close() drops at once).
    public func releaseAll(_ resources: [BrowserReplResource]) {
        lock.withLock {
            for resource in resources where resource.scope != .lifetime {
                if resource.isMemory { addLocked(-(held[resource] ?? 0), to: .sessionMemoryBytes) }
                held[resource] = nil
            }
        }
    }

    /// What `resource` holds now.
    public func held(_ resource: BrowserReplResource) -> Int {
        lock.withLock { held[resource] ?? 0 }
    }

    /// The most `resource` held at once since the ledger was made.
    public func peak(_ resource: BrowserReplResource) -> Int {
        lock.withLock { peaks[resource] ?? 0 }
    }

    /// Everything held now that a holder still has to release (lifetime
    /// resources are spent, not held). Empty once a closed session drained.
    public var outstanding: [BrowserReplResource: Int] {
        lock.withLock { held.filter { $0.key.scope != .lifetime && $0.value != 0 } }
    }

    private func reserveLocked(
        _ amount: Int,
        of resource: BrowserReplResource,
        replacing old: Int,
        each: Int?,
        force: Bool
    ) -> BrowserReplResourceLimitError? {
        let current = held[resource] ?? 0
        let others = current - old
        if !force, let item = each ?? limits.each(resource), amount > item {
            return BrowserReplResourceLimitError(resource: resource, limit: item, isPerItem: true, held: current, requested: amount)
        }
        let limit = limits[resource]
        if !force, amount > limit - others {
            return BrowserReplResourceLimitError(resource: resource, limit: limit, isPerItem: false, held: others, requested: amount)
        }
        let growth = amount - old
        if resource.isMemory, !resource.isMeasured, !force, growth > 0 {
            let memory = held[.sessionMemoryBytes] ?? 0
            let total = limits[.sessionMemoryBytes]
            if growth > total - memory {
                return BrowserReplResourceLimitError(resource: .sessionMemoryBytes, limit: total, isPerItem: false, held: memory, requested: growth)
            }
        }
        addLocked(growth, to: resource)
        if resource.isMemory { addLocked(growth, to: .sessionMemoryBytes) }
        return nil
    }

    /// Adds `delta` to what `resource` holds and records its peak. Call
    /// with `lock` held.
    private func addLocked(_ delta: Int, to resource: BrowserReplResource) {
        let now = (held[resource] ?? 0) + delta
        held[resource] = now != 0 ? now : nil
        if now > (peaks[resource] ?? 0) { peaks[resource] = now }
    }
}
