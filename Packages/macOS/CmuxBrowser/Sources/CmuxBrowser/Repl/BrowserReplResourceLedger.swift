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
    /// Driver results (and errors) the runtime has not taken yet.
    case driverResultBytes
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
    /// Bytes the session's fs (and its spill files and file chooser
    /// answers) wrote over its life.
    case fileBytesWritten
    /// Entries the session's fs created, made, renamed or removed over its life.
    case fileEntryChanges

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
        case .fileBytesWritten, .fileEntryChanges: .lifetime
        default: .atOnce
        }
    }

    /// Whether the amounts are bytes (else items).
    public var isBytes: Bool {
        switch self {
        case .waitingCellSourceBytes, .retainedOutputBytes, .spilledOutputBytes, .requestBytes,
             .driverResultBytes, .fetchBodyBytes, .queuedEventBytes, .fileBytesWritten:
            true
        default:
            false
        }
    }

    /// What the limit counts, as an error names it.
    public var title: String {
        switch self {
        case .waitingCells: "cells waiting to run"
        case .waitingCellSourceBytes: "source of the cells waiting to run"
        case .retainedOutputBytes: "output a cell keeps in memory"
        case .spilledOutputBytes: "output a cell spills to its file"
        case .queuedDriverCalls: "browser calls waiting for a slot"
        case .runningDriverCalls: "browser calls running"
        case .requestBytes: "parameters of the browser calls and fetches waiting or running"
        case .driverResultBytes: "browser call results the session's JavaScript has not taken yet"
        case .queuedFetches: "fetches waiting for a slot"
        case .requestPhaseFetches: "fetches waiting for their response headers"
        case .openFetches: "open fetches"
        case .fetchBodyBytes: "response bodies the session's fetches hold"
        case .queuedEvents: "page events waiting for the session's thread"
        case .queuedEventBytes: "bytes of the page events waiting for the session's thread"
        case .heldEvents: "page events held back between cells"
        case .pendingTimers: "pending timers"
        case .fileBytesWritten: "bytes the session's fs writes"
        case .fileEntryChanges: "file changes (files created, directories made, entries renamed or removed)"
        }
    }

    /// What the caller can do about it.
    public var remedy: String {
        switch self {
        case .waitingCells, .waitingCellSourceBytes: "wait for them to finish"
        case .retainedOutputBytes, .spilledOutputBytes: "print less, or write it to a file"
        case .queuedDriverCalls, .runningDriverCalls, .requestBytes, .queuedFetches,
             .requestPhaseFetches, .openFetches:
            "await some before starting more"
        case .driverResultBytes: "await results before starting more calls"
        case .fetchBodyBytes: "await some before starting more, or download large files in a tab (page.waitForEvent(\"download\"))"
        case .queuedEvents, .queuedEventBytes, .heldEvents: "let the session's thread take them"
        case .pendingTimers: "clear some first"
        case .fileBytesWritten: "reset the session (cmux browser repl reset NAME) to write more"
        case .fileEntryChanges: "reset the session (cmux browser repl reset NAME) to make more"
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
            .driverResultBytes: 512 << 20,
            .queuedFetches: 256,
            .requestPhaseFetches: 16,
            .openFetches: 64,
            .fetchBodyBytes: 128 << 20,
            .queuedEvents: 10_000,
            .queuedEventBytes: 64 << 20,
            .heldEvents: 10_000,
            .pendingTimers: 10_000,
            .fileBytesWritten: 2 << 30,
            .fileEntryChanges: 100_000,
        ],
        items: [
            // One browser call's parameters (the fetch and readFile limit).
            .requestBytes: 64 << 20,
            .driverResultBytes: 64 << 20,
            // One fetch's response body.
            .fetchBodyBytes: 64 << 20,
            // One page event; a larger one arrives withheld.
            .queuedEventBytes: 1 << 20,
            // One writeFile, copyFile or file chooser answer.
            .fileBytesWritten: 256 << 20,
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
            let left = (held[resource] ?? 0) - amount
            assert(left >= 0, "\(resource) released more than it reserved")
            held[resource] = left > 0 ? left : nil
        }
    }

    /// Releases everything held of `resources` (what close() drops at once).
    public func releaseAll(_ resources: [BrowserReplResource]) {
        lock.withLock {
            for resource in resources where resource.scope != .lifetime { held[resource] = nil }
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
        let now = others + amount
        held[resource] = now != 0 ? now : nil
        if now > (peaks[resource] ?? 0) { peaks[resource] = now }
        return nil
    }
}
