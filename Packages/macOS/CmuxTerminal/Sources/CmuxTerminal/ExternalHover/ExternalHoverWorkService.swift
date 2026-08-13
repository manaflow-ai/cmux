internal import Foundation
public import CmuxTerminalCore
public import GhosttyKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// (B) ExternalHover — the actor that owns hover-candidate resolution,
/// caching, and every C read/set/clear call this mechanism makes.
///
/// Placed in `CmuxTerminal`, not `CmuxTerminalCore` (review Blocking 8):
/// it depends on `TerminalSurfaceRuntimeTeardownCoordinator` and
/// `RuntimeSurfaceLifetimeID`, both `CmuxTerminal`-only — `CmuxTerminal`
/// already depends on `CmuxTerminalCore`, so placing this service in Core
/// would be circular. `TerminalWrappedPathCellSpan`, the resolver, and the
/// mailbox/coordinator pure parts stay in Core; this actor is their sole
/// concrete consumer for (B).
///
/// One process-wide instance, injected the same way as
/// `TerminalSurfaceRuntimeTeardownCoordinator`. AppKit wiring (submitting
/// real requests from `GhosttyNSView`, and the concrete
/// `readPhysicalRows`/`callSetter`/`callClear` closures that actually call
/// `ghostty_surface_*`) is a later pass — this actor is complete and
/// independently testable with injected closures now.
public actor ExternalHoverWorkService {
    /// Reads the exact physical-row text for `[topRow, topRow+rowCount)`
    /// (viewport-relative, matching Ghostty's own contract), using the
    /// bounded C access `lease` borrows.
    ///
    /// review B3/final-spec §2.3/§9 — the A-B-A metrics contract: the
    /// implementation must capture grid metrics BEFORE the raw read,
    /// perform the read, capture metrics AFTER, and return a
    /// ``TerminalPhysicalRowsSnapshot`` only when BOTH captures match
    /// `expectedColumns`/`expectedViewportRows` (the values the request
    /// was built against) — all within the SAME lease. `nil` on any
    /// failure, including a metrics mismatch (a resize/reflow raced the
    /// read). Production's implementation
    /// (`GhosttyApp.externalHoverWorkService`'s closure) delegates the
    /// actual before/after comparison to
    /// ``coherentPhysicalRowsSnapshot(rawText:topRow:expectedRowCount:expectedColumns:expectedViewportRows:metricsBefore:metricsAfter:)``
    /// — the same function tests call — so the contract itself is
    /// shared, not duplicated.
    public typealias ReadPhysicalRows = @Sendable (
        _ lease: ExternalHoverSurfaceLease,
        _ topRow: UInt32,
        _ rowCount: UInt32,
        _ expectedColumns: Int,
        _ expectedViewportRows: UInt32
    ) -> TerminalPhysicalRowsSnapshot?

    /// Calls `ghostty_surface_set_external_link_hover` (or an injected
    /// double) using `lease`. `nil`/`.zero` on rejection. `hostEventID` is
    /// (C) diagnostics' correlation bridge (design v4 §2) — the exact
    /// `requestGeneration` value this candidate was resolved under, so a
    /// setter rejection or accepted-activation's later render entries can
    /// be attributed back to this specific request.
    public typealias CallSetter = @Sendable (
        _ lease: ExternalHoverSurfaceLease,
        _ topRow: UInt32,
        _ rowCount: UInt32,
        _ text: String,
        _ ranges: [ExternalHoverCellRangeValue],
        _ hostEventID: UInt64
    ) -> HoverActivationTokenValue?

    /// Calls `ghostty_surface_clear_external_link_hover` (or an injected
    /// double) using `lease`.
    public typealias CallClear = @Sendable (
        _ lease: ExternalHoverSurfaceLease,
        _ token: HoverActivationTokenValue
    ) -> Void

    /// (C) ExternalHover diagnostics — calls
    /// `ghostty_surface_drain_external_hover_diagnostics` (or an injected
    /// double) using `lease`, destructively draining up to `capacity`
    /// oldest live entries. Returns the entries copied plus the ring's
    /// raw monotonic cumulative dropped-count (NOT a delta — the actor
    /// computes its own delta per lifetime, design v4 §3.3).
    public typealias DrainDiagnostics = @Sendable (
        _ lease: ExternalHoverSurfaceLease,
        _ capacity: Int
    ) -> (entries: [ExternalHoverDiagEntryValue], droppedCountCumulative: UInt64)

    /// (C) diagnostics — review B1: an injectable seam for design v4 §7
    /// guard 4's "gate OFF ⇒ no allocation/ring/demand work", matching
    /// `ExternalHoverOwnerCoordinator.DiagnosticsEnabled`. Production
    /// composition never overrides this; tests inject a controllable
    /// closure, since the real gate is a process-wide memoized `static
    /// let`.
    public typealias DiagnosticsEnabled = @Sendable () -> Bool

    /// (C) diagnostics — review round3 B3: computes `resolveFully`'s
    /// `stage=read` metrics (`textBytes`/`newlineCount`/`rawEntryCount`).
    /// Production composition never overrides this (the default IS
    /// `defaultReadMetrics`, the real computation); tests wrap it with a
    /// counting double so "gate OFF ⇒ zero invocations, gate ON ⇒ exactly
    /// one invocation with the real values" becomes an assertion instead
    /// of a source-shape inspection of `resolveFully` itself.
    public typealias ReadMetricsCalculator = @Sendable (String) -> ExternalHoverReadMetrics

    /// Bounded per-drain capacity — matches the Zig ring's own fixed
    /// capacity (64), so one drain call always empties the ring in a
    /// single round-trip under normal (non-pathological) hover rates.
    private static let diagnosticsDrainCapacity = 64

    /// review B3 — the pure half of the A-B-A metrics contract, called by
    /// BOTH production's `readPhysicalRows` closure (which supplies the
    /// two live `ghostty_surface_grid_metrics` captures) and tests
    /// (which supply synthetic ones) — the SAME function, so the
    /// contract can never silently diverge between what production
    /// actually does and what a test merely asserts about it.
    ///
    /// - Returns: A snapshot built from `rawText` when both `metricsBefore`
    ///   and `metricsAfter` equal `expectedColumns`/`expectedViewportRows`;
    ///   `nil` on any mismatch (a resize/reflow raced the read) or if
    ///   `rawText` itself can't reconcile with `expectedRowCount`/
    ///   `expectedColumns` (``TerminalPhysicalRowsSnapshot``'s own
    ///   `init?`).
    public static func coherentPhysicalRowsSnapshot(
        rawText: String,
        topRow: UInt32,
        expectedRowCount: UInt32,
        expectedColumns: Int,
        expectedViewportRows: UInt32,
        metricsBefore: (columns: Int, rows: UInt32),
        metricsAfter: (columns: Int, rows: UInt32)
    ) -> TerminalPhysicalRowsSnapshot? {
        guard metricsBefore.columns == expectedColumns, metricsBefore.rows == expectedViewportRows,
              metricsAfter.columns == expectedColumns, metricsAfter.rows == expectedViewportRows
        else {
            return nil
        }
        return TerminalPhysicalRowsSnapshot(
            rawText: rawText, topRow: topRow, expectedRowCount: expectedRowCount, columns: expectedColumns
        )
    }

    private let teardownCoordinator: TerminalSurfaceRuntimeTeardownCoordinator
    private let resolver: TerminalPathResolver
    private let readPhysicalRows: ReadPhysicalRows
    private let callSetter: CallSetter
    private let callClear: CallClear
    private let drainDiagnostics: DrainDiagnostics
    private let diagnosticsEnabled: DiagnosticsEnabled
    /// (C) diagnostics — review round3 B3. `resolveFully` routes its
    /// `stage=read` metrics through this calculator only when diagnostics
    /// are enabled; the default closure calls the real
    /// `defaultReadMetrics` implementation. Tests wrap it with a counting
    /// double so "gate OFF ⇒ zero invocations, gate ON ⇒ exactly one
    /// invocation with the real values" remains observable.
    private let readMetricsCalculator: ReadMetricsCalculator

    /// (C) diagnostics — review B5: shared with `teardownCoordinator`'s
    /// own final teardown drain (`TerminalSurfaceRuntimeTeardownCoordinator
    /// .droppedCountTracker` — the SAME instance, read off that
    /// dependency at `init`, never a private dictionary of this actor's
    /// own), so `droppedDelta` is linearized against ONE per-lifetime
    /// baseline across every drain trigger and is only ever reported once
    /// per actual drop batch, never re-reported on a later drain — by
    /// EITHER path — that finds no NEW drops (design v4 §3.3).
    private let droppedCountTracker: ExternalHoverDroppedCountTracker

    /// (C) diagnostics — review round2 B5: shared with
    /// `teardownCoordinator`'s own final teardown drain the same way
    /// `droppedCountTracker` is — see `ExternalHoverSurfaceSerialRegistry`'s
    /// own doc.
    private let surfaceSerialRegistry: ExternalHoverSurfaceSerialRegistry

    internal var cachesByLifetime: [RuntimeSurfaceLifetimeID: ExternalHoverCandidateCache] = [:]
    /// Lifetimes `invalidateSurface` has tombstoned. A request for a
    /// closed lifetime can never rebuild a cache entry, even if it
    /// otherwise looks current by generation — review Blocking 5's fix
    /// for the contradiction in the original design doc ("dropCache" vs.
    /// "the next process rebuilds it").
    private var closedLifetimes: Set<RuntimeSurfaceLifetimeID> = []

    public init(
        teardownCoordinator: TerminalSurfaceRuntimeTeardownCoordinator,
        resolver: TerminalPathResolver = TerminalPathResolver(),
        readPhysicalRows: @escaping ReadPhysicalRows,
        callSetter: @escaping CallSetter,
        callClear: @escaping CallClear,
        drainDiagnostics: @escaping DrainDiagnostics,
        diagnosticsEnabled: @escaping DiagnosticsEnabled = { ExternalHoverDiagnosticsGate.isEnabled },
        readMetricsCalculator: @escaping ReadMetricsCalculator = { ExternalHoverWorkService.defaultReadMetrics($0) }
    ) {
        self.teardownCoordinator = teardownCoordinator
        self.resolver = resolver
        self.readPhysicalRows = readPhysicalRows
        self.callSetter = callSetter
        self.callClear = callClear
        self.drainDiagnostics = drainDiagnostics
        self.diagnosticsEnabled = diagnosticsEnabled
        self.readMetricsCalculator = readMetricsCalculator
        // (C) diagnostics — review B5: the SAME instance
        // `teardownCoordinator`'s own final teardown drain reads, never a
        // separate one — this is what makes the shared baseline actually
        // shared rather than each side keeping (or, before this fix, one
        // side not even keeping) its own.
        self.droppedCountTracker = teardownCoordinator.droppedCountTracker
        self.surfaceSerialRegistry = teardownCoordinator.surfaceSerialRegistry
    }

    /// The ONLY entry point `GhosttyNSView`'s AppKit event path calls
    /// (wired in a later pass). `nonisolated` and fire-and-forget — the
    /// main-thread hot path never `await`s this actor (review Blocking 1:
    /// generalized past its literal "no `DispatchQueue.main.sync`" wording
    /// to "no synchronous wait on this actor from the main event path" at
    /// all).
    ///
    /// Returns the underlying `Task` so deterministic tests can
    /// `await task.value` instead of a real-time poll; production callers
    /// (Pass 2's AppKit wiring) discard it — `@discardableResult` keeps
    /// that a plain statement, not an error.
    @discardableResult
    public nonisolated func submit(_ request: ExternalHoverWorkRequest) -> Task<Void, Never> {
        Task { await self.process(request) }
    }

    /// (B) wiring review Blocking 5 — acceptance boundary. `mirror`'s
    /// CURRENT snapshot, not any value captured earlier, must match
    /// `request.lifetimeID`/`requestGeneration` and report both
    /// eligible and visible. A stale/superseded request fails this and
    /// the caller must do nothing observable — no setter, no clear, no
    /// cache write, and (for `withdrawCurrentCandidate`) no mailbox
    /// mutation, since a stale request must never clear a newer owner.
    /// (C) diagnostics — design v4 §6.1: ONE snapshot capture, then a
    /// single structured verdict derived from it, reused for BOTH the
    /// guard's accept/reject decision and the `stage=currentness` log
    /// line — never a second mirror read for "the reason" after the
    /// guard already decided. `checkpoint` names match the current
    /// code's own positions exactly (`processStart`/`afterResolve`/
    /// `beforeSetter`/`withdrawal`), per the design doc's explicit
    /// requirement not to invent new checkpoint names.
    enum CurrentnessVerdict: Equatable {
        case current
        case dropped(reason: String)

        var isCurrent: Bool { self == .current }
    }

    // `internal` (not `private`): test-only direct access via
    // `@testable import`, so currentness classification can be unit
    // tested against a real actor instance without duplicating this
    // logic in the test file (guard 1's "don't duplicate structured
    // judgment" applies to tests too, not just production call sites).
    func currentnessVerdict(_ request: ExternalHoverWorkRequest) -> CurrentnessVerdict {
        guard !closedLifetimes.contains(request.lifetimeID) else {
            return .dropped(reason: "closedLifetime")
        }
        let snapshot = request.mirror.captureHoverCallbackSnapshot()
        guard snapshot.lifetimeID == request.lifetimeID else {
            return .dropped(reason: "lifetimeMismatch")
        }
        guard snapshot.hoverEventID == request.requestGeneration else {
            return .dropped(reason: "eventMismatch")
        }
        guard snapshot.eligible else { return .dropped(reason: "ineligible") }
        guard snapshot.visible else { return .dropped(reason: "notVisible") }
        return .current
    }

    /// (C) diagnostics — review B3. `withdrawCurrentCandidate` must NOT
    /// reuse `currentnessVerdict` (which requires `eligible && visible`)
    /// as its guard: the real Cmd-release production path publishes
    /// `eligible == false` to the mirror SPECIFICALLY as the trigger for a
    /// withdrawal, so a guard that rejects ineligible/invisible snapshots
    /// would reject the exact withdrawal it was meant to authorize,
    /// silently dropping the clear + drain. Withdrawal authorization keeps
    /// the SAME lifetime/event guard (a stale request must never clear a
    /// newer owner) but treats `eligible == false` / `visible == false` as
    /// valid CAUSES to withdraw rather than rejection reasons.
    enum WithdrawalAuthorizationVerdict: Equatable {
        case authorized
        case rejected(reason: String)

        var isAuthorized: Bool { self == .authorized }
    }

    // `internal`, matching `currentnessVerdict`'s own visibility rationale.
    func withdrawalAuthorizationVerdict(_ request: ExternalHoverWorkRequest) -> WithdrawalAuthorizationVerdict {
        guard !closedLifetimes.contains(request.lifetimeID) else {
            return .rejected(reason: "closedLifetime")
        }
        let snapshot = request.mirror.captureHoverCallbackSnapshot()
        guard snapshot.lifetimeID == request.lifetimeID else {
            return .rejected(reason: "lifetimeMismatch")
        }
        guard snapshot.hoverEventID == request.requestGeneration else {
            return .rejected(reason: "eventMismatch")
        }
        return .authorized
    }

    private func isAuthorizedForWithdrawal(_ request: ExternalHoverWorkRequest) -> Bool {
        let verdict = withdrawalAuthorizationVerdict(request)
#if DEBUG
        // Review round2 B4: the injected `diagnosticsEnabled()`, not the
        // static gate directly — same "one consistent snapshot" rationale
        // as `resolveFully`/`logSetter`, so this stays consistent and
        // testable via the same seam.
        if diagnosticsEnabled() {
            switch verdict {
            case .authorized:
                logDebugEvent(
                    "link.externalHover stage=currentness surfaceSerial=\(request.surfaceSerial) event=\(request.requestGeneration) " +
                    "checkpoint=withdrawal outcome=current"
                )
            case .rejected(let reason):
                logDebugEvent(
                    "link.externalHover stage=currentness surfaceSerial=\(request.surfaceSerial) event=\(request.requestGeneration) " +
                    "checkpoint=withdrawal outcome=dropped reason=\(reason)"
                )
            }
        }
#endif
        return verdict.isAuthorized
    }

    private func isCurrent(_ request: ExternalHoverWorkRequest, checkpoint: String) -> Bool {
        let verdict = currentnessVerdict(request)
#if DEBUG
        // Review round2 B4: same rationale as `isAuthorizedForWithdrawal`
        // above — the injected gate, not the static one.
        if diagnosticsEnabled() {
            switch verdict {
            case .current:
                logDebugEvent(
                    "link.externalHover stage=currentness surfaceSerial=\(request.surfaceSerial) event=\(request.requestGeneration) " +
                    "checkpoint=\(checkpoint) outcome=current"
                )
            case .dropped(let reason):
                logDebugEvent(
                    "link.externalHover stage=currentness surfaceSerial=\(request.surfaceSerial) event=\(request.requestGeneration) " +
                    "checkpoint=\(checkpoint) outcome=dropped reason=\(reason)"
                )
            }
        }
#endif
        return verdict.isCurrent
    }

    /// Review round3 B1: called ONLY under the caller's own `diagnosticsOn`
    /// snapshot — this dictionary write + lock is diagnostics-correlation
    /// work with no other purpose, so design v4 §7 guard 4 ("gate OFF ⇒
    /// no allocation/ring/demand work") applies to it exactly like the
    /// metric computation in `resolveFully` does. Before this fix it ran
    /// unconditionally regardless of the gate; the LOOKUP in
    /// `defaultDrainExternalHoverDiagnostics` remains what actually makes
    /// the registered value useful, but the WRITE itself must stay gated
    /// too. Registering on every request while the gate is on (rather
    /// than only inside some other diagnostics-only branch) is what
    /// guarantees a lifetime's serial is already known by the time its
    /// final teardown drain runs.
    private func rememberSurfaceSerial(_ request: ExternalHoverWorkRequest) {
        surfaceSerialRegistry.register(request.surfaceSerial, for: request.lifetimeID)
    }

    private func process(_ request: ExternalHoverWorkRequest) async {
        if diagnosticsEnabled() {
            rememberSurfaceSerial(request)
        }
        // Checkpoint 1 (start).
        guard isCurrent(request, checkpoint: "processStart") else { return }

        if let cached = cachesByLifetime[request.lifetimeID],
           cached.cwd == request.cwd,
           cached.contains(cell: request.cell) {
            await applySetter(using: cached, request: request)
            return
        }

        guard let resolvedCache = await resolveFully(request) else {
            // resolver nil, read failure, or out-of-bounds — the shared
            // withdrawal path handles "no candidate" uniformly; a genuine
            // read/bounds failure that never got as far as attempting a
            // resolve also just withdraws (there is nothing stale to
            // leave behind either way).
            await withdrawCurrentCandidate(request: request, reason: "noCandidate")
            return
        }

        // Checkpoint 2 (after fs resolve).
        guard isCurrent(request, checkpoint: "afterResolve") else { return }
        await applySetter(using: resolvedCache, request: request)
    }

    /// Bounded 7-row read (clicked row + up to 3 adjacent each side,
    /// clamped to the viewport — #8810 widened this from the original
    /// 3-row window to match the geometry-aware evaluator's own
    /// `maxWrappedRows` span), resolved through the shared pure resolver
    /// (review Blocking 6's "reuse pure resolver/tokenizer only, never
    /// the click helper's whole-viewport read"). Returns a cache entry
    /// with `ranges` already materialized to absolute viewport
    /// coordinates, or `nil` on any failure (no candidate, no seed, an
    /// unreadable or A-B-A-incoherent read, or the read lease was
    /// refused).
    private func resolveFully(_ request: ExternalHoverWorkRequest) async -> ExternalHoverCandidateCache? {
#if DEBUG
        // Review round2 B4: ONE snapshot for this whole call — the
        // injected `diagnosticsEnabled()` (never the static
        // `ExternalHoverDiagnosticsGate.isEnabled` directly), matching
        // every other gated call this actor makes and making the gate
        // itself injectable/testable here too. Every metric computation
        // AND log call below lives inside `if diagnosticsOn { ... }` —
        // never computed-then-passed-to-a-gated-log-function, which is
        // what let `newlineCount`/`rawEntryCount`/`textBytes` scan/
        // allocate on every call regardless of the gate before this fix
        // (design v4 §7 guard 4: "gate OFF ⇒ no allocation/ring/demand
        // work").
        let diagnosticsOn = diagnosticsEnabled()
        // Review B4: `topRow`/`rowCount` (the read window's own geometry,
        // not folded into a differently-named field), plus `newlineCount`/
        // `rawEntryCount`/`splitResultCount` — independent, purely
        // string-derived facts about `text` that explain a `splitFailed`/
        // `clickedIndexOutOfBounds` outcome without re-running
        // `splitPhysicalViewportRows`'s own judgment (guard 1): `newlineCount`
        // is the raw `\n` count, `rawEntryCount` is what a bare newline
        // split yields BEFORE that function's own trailing-empty trim/pad,
        // and `splitResultCount` is its actual output count. Callers gate
        // with `diagnosticsOn` themselves — this no longer re-checks the
        // gate internally. `expectedRows` is design v4's own read-schema
        // field (what the read WANTED, i.e. `Int(rowCount)`) — round1's B4
        // fix dropped it when adding `topRow`/`rowCount`, but v4 specifies
        // all three, so it stays alongside them even though its value is
        // always identical to `rowCount` here.
        func logRead(
            outcome: String, reason: String? = nil, topRow: UInt32 = 0, rowCount: UInt32 = 0,
            expectedRows: Int = 0, textBytes: Int = 0, newlineCount: Int = 0, rawEntryCount: Int = 0,
            splitResultCount: Int = 0
        ) {
            logDebugEvent(
                "link.externalHover stage=read surfaceSerial=\(request.surfaceSerial) event=\(request.requestGeneration) " +
                "topRow=\(topRow) rowCount=\(rowCount) expectedRows=\(expectedRows) textBytes=\(textBytes) " +
                "newlineCount=\(newlineCount) rawEntryCount=\(rawEntryCount) splitResultCount=\(splitResultCount) " +
                "outcome=\(outcome)" + (reason.map { " reason=\($0)" } ?? "")
            )
        }
        // `candidateLength`: the resolved candidate's path LENGTH only
        // (never the path itself, per design v4 §5's secrecy policy).
        // `directionsTried`: `seed.directions.count` — 1 for an
        // unambiguous seed, 2 for a bare-relative seed that tries both
        // `.previous` and `.next` — read straight off the seed the
        // resolver itself already built, never re-derived. Callers gate
        // with `diagnosticsOn` themselves — this no longer re-checks the
        // gate internally.
        func logResolve(
            outcome: String, reason: String? = nil, spanCount: Int = 0,
            candidateLength: Int = 0, directionsTried: Int = 0,
            gridColumns: Int? = nil, clickedLastCol: Int? = nil,
            prevLastCol: Int? = nil, nextLastCol: Int? = nil,
            evaluatorReason: String? = nil
        ) {
            let geometryFields: String
            if let gridColumns, let clickedLastCol, let prevLastCol, let nextLastCol {
                geometryFields = "gridColumns=\(gridColumns) clickedLastCol=\(clickedLastCol) " +
                    "prevLastCol=\(prevLastCol) nextLastCol=\(nextLastCol) "
            } else {
                geometryFields = ""
            }
            logDebugEvent(
                "link.externalHover stage=resolve surfaceSerial=\(request.surfaceSerial) event=\(request.requestGeneration) " +
                "spanCount=\(spanCount) candidateLength=\(candidateLength) directionsTried=\(directionsTried) " +
                geometryFields + "outcome=\(outcome)" + (reason.map { " reason=\($0)" } ?? "") +
                (evaluatorReason.map { " evaluatorReason=\($0)" } ?? "")
            )
        }
#endif
        let clickedRow = request.cell.row
        // #8810 — widened from clicked±1 (3 rows) to clicked±3 (7 rows,
        // matching `TerminalPhysicalRowWindow.maxSnapshotRows`): the
        // shared geometry-aware evaluator can span up to 4 rows on
        // either side of the clicked one, and the read window is the
        // one thing click (which reads its whole viewport) and hover
        // must deliberately keep IDENTICAL for final-spec §13's
        // row0/row1/row2 parity to hold at the system level, not just
        // inside the resolver's own tests.
        let maxSpan = UInt32(TerminalPhysicalRowWindow.maxSnapshotRows - 1) / 2
        let topRow = clickedRow > maxSpan ? clickedRow - maxSpan : 0
        guard clickedRow < request.viewportRowCount else {
#if DEBUG
            if diagnosticsOn {
                logRead(outcome: "rejected", reason: "noRowsInViewport", topRow: topRow, rowCount: 0, expectedRows: 0)
            }
#endif
            return nil
        }
        let rowCount = min(UInt32(TerminalPhysicalRowWindow.maxSnapshotRows), request.viewportRowCount - topRow)
        guard rowCount > 0 else {
#if DEBUG
            if diagnosticsOn {
                logRead(outcome: "rejected", reason: "noRowsInViewport", topRow: topRow, rowCount: rowCount, expectedRows: Int(rowCount))
            }
#endif
            return nil
        }

        // Just-in-time read lease: acquired immediately before the C
        // call, released immediately after — never held across the fs
        // probe that follows (review Blocking 4).
        guard let readLease = await teardownCoordinator.acquireExternalHoverLease(
            lifetimeID: request.lifetimeID,
            surface: request.surface
        ) else {
#if DEBUG
            if diagnosticsOn {
                logRead(outcome: "rejected", reason: "leaseRefused", topRow: topRow, rowCount: rowCount, expectedRows: Int(rowCount))
            }
#endif
            return nil
        }
        // review B3 — the reader itself performs the A-B-A metrics
        // check (before/read/after, all inside this SAME lease) and
        // returns a coherent snapshot only when both captures match the
        // request's own expected columns/viewport rows; `nil` covers a
        // real read failure AND a metrics mismatch (a resize/reflow
        // raced the read) uniformly.
        let snapshot = readPhysicalRows(readLease, topRow, rowCount, request.gridColumns, request.viewportRowCount)
        await teardownCoordinator.releaseExternalHoverLease(readLease)
        guard let snapshot else {
#if DEBUG
            if diagnosticsOn {
                logRead(outcome: "rejected", reason: "readFailed", topRow: topRow, rowCount: rowCount, expectedRows: Int(rowCount))
            }
#endif
            return nil
        }
        let text = snapshot.rawText
#if DEBUG
        // Review B4/round3 B3: computed ONLY when the gate is on, via the
        // injected `readMetricsCalculator` (never inline) — routing
        // through the seam rather than duplicating its formula here is
        // what makes "gate OFF ⇒ zero invocations" an observable,
        // countable fact for a test, not just a source-shape convention.
        var textBytes = 0
        var newlineCount = 0
        var rawEntryCount = 0
        if diagnosticsOn {
            let metrics = readMetricsCalculator(text)
            textBytes = metrics.textBytes
            newlineCount = metrics.newlineCount
            rawEntryCount = metrics.rawEntryCount
        }
#endif

        // review B3 — `snapshot.rows`/`snapshot.columns` ONLY from here
        // on, never `request.gridColumns` again: the snapshot is the
        // single coherent source of truth this whole resolve reasons
        // about, matching ``TerminalPhysicalRowsSnapshot``'s own doc.
        let lines = snapshot.rows
        let clickedIndex = Int(clickedRow - topRow)
        guard lines.indices.contains(clickedIndex) else {
#if DEBUG
            if diagnosticsOn {
                logRead(
                    outcome: "rejected", reason: "clickedIndexOutOfBounds", topRow: topRow, rowCount: rowCount,
                    expectedRows: Int(rowCount), textBytes: textBytes, newlineCount: newlineCount,
                    rawEntryCount: rawEntryCount, splitResultCount: lines.count
                )
            }
#endif
            return nil
        }
        let clickedLine = lines[clickedIndex]
#if DEBUG
        if diagnosticsOn {
            logRead(
                outcome: "accepted", topRow: topRow, rowCount: rowCount, expectedRows: Int(rowCount),
                textBytes: textBytes, newlineCount: newlineCount, rawEntryCount: rawEntryCount,
                splitResultCount: lines.count
            )
        }
#endif

        let resolved: TerminalWrappedPathResolution
        let directionsTried: Int
        if let seed = resolver.wrappedPathSeed(
            in: clickedLine, column: request.cell.column, cwd: request.cwd, columns: snapshot.columns
        ) {
            // cmux-shared-behavior policy — the SAME entry point the click
            // path calls (`GhosttyTerminalView.prepareCommandClickContext`),
            // with `purpose: .hover` so it can never reach the conservative
            // click-only fallback.
            directionsTried = seed.directions.count
            var candidate: TerminalWrappedPathResolution?
#if DEBUG
            var evaluatorOutcome: TerminalWrappedResolutionOutcome?
            if diagnosticsOn {
                let resolution = resolver.resolveWrappedCandidateWithOutcome(
                    seed: seed, rows: lines, clickedIndex: clickedIndex, columns: snapshot.columns, cwd: request.cwd,
                    purpose: .hover
                )
                candidate = resolution.candidate
                evaluatorOutcome = resolution.evaluatorOutcome
            } else {
                candidate = resolver.resolveWrappedCandidate(
                    seed: seed, rows: lines, clickedIndex: clickedIndex, columns: snapshot.columns, cwd: request.cwd,
                    purpose: .hover
                )
            }
#else
            candidate = resolver.resolveWrappedCandidate(
                seed: seed, rows: lines, clickedIndex: clickedIndex, columns: snapshot.columns, cwd: request.cwd,
                purpose: .hover
            )
#endif
            guard let candidate else {
#if DEBUG
                if diagnosticsOn {
                    let previousLastCol = clickedIndex > 0
                        ? (lines[clickedIndex - 1].lastNonWhitespaceColumn ?? -1)
                        : -1
                    let nextLastCol = clickedIndex + 1 < lines.count
                        ? (lines[clickedIndex + 1].lastNonWhitespaceColumn ?? -1)
                        : -1
                    logResolve(
                        outcome: "rejected", reason: "noCandidate", directionsTried: directionsTried,
                        gridColumns: snapshot.columns,
                        clickedLastCol: clickedLine.lastNonWhitespaceColumn ?? -1,
                        prevLastCol: previousLastCol,
                        nextLastCol: nextLastCol,
                        evaluatorReason: evaluatorOutcome?.diagnosticName ?? "unavailable"
                    )
                }
#endif
                return nil
            }
            resolved = candidate
        } else {
            // A leading row with a verified single-cell layout cannot produce
            // a normal seed because the shared token path remains
            // ASCII-only. The fallback is still the same resolver entry
            // point used by click, but only its exact-range branch is eligible
            // for hover; conservative text-only joins remain click-only.
            directionsTried = 1
            let nextRow = clickedIndex + 1 < lines.count ? lines[clickedIndex + 1] : nil
            guard let candidate = resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedLine,
                column: request.cell.column,
                nextRow: nextRow,
                cwd: request.cwd,
                purpose: .hover
            ) else {
#if DEBUG
                if diagnosticsOn {
                    logResolve(outcome: "rejected", reason: "noSeed")
                }
#endif
                return nil
            }
            resolved = candidate
        }

        // design-next-round-bundle-8810.md §1 rule 5 — a candidate resolved
        // through the conservative click-only text extraction fallback
        // carries no column data at all
        // (`TerminalWrappedCellSpans.unavailableNonASCIIRow`, never a
        // `TerminalWrappedPathCellSpan` array); hover must never guess a
        // column range. The verified leading-row branch is safe here because
        // it returns `.available` exact spans.
        guard case .available(let spans) = resolved.cellSpans else {
#if DEBUG
            if diagnosticsOn {
                logResolve(
                    outcome: "rejected", reason: "cellSpansUnavailableNonASCIIRow",
                    candidateLength: resolved.path.count, directionsTried: directionsTried
                )
            }
#endif
            return nil
        }
        let ranges = spans.compactMap { span -> ExternalHoverCellRangeValue? in
            let absoluteRow = Int(clickedRow) + span.rowOffsetFromClicked
            guard absoluteRow >= 0, absoluteRow <= UInt16.max,
                  span.startColumn >= 0, span.endColumn <= Int(UInt16.max) + 1 else { return nil }
            return ExternalHoverCellRangeValue(
                row: UInt16(absoluteRow),
                startColumn: UInt16(span.startColumn),
                endColumn: UInt16(span.endColumn)
            )
        }
        guard ranges.count == spans.count else {
#if DEBUG
            if diagnosticsOn {
                logResolve(
                    outcome: "rejected", reason: "rangeConversionFailed", spanCount: spans.count,
                    candidateLength: resolved.path.count, directionsTried: directionsTried
                )
            }
#endif
            return nil
        }
#if DEBUG
        if diagnosticsOn {
            logResolve(
                outcome: "accepted", spanCount: ranges.count, candidateLength: resolved.path.count,
                directionsTried: directionsTried
            )
        }
#endif

        return ExternalHoverCandidateCache(
            lifetimeID: request.lifetimeID,
            cwd: request.cwd,
            topRow: topRow,
            rowCount: rowCount,
            physicalRowsText: text,
            ranges: ranges,
            path: resolved.path,
            activationToken: nil
        )
    }

    /// Calls the setter — inside the SAME mailbox critical section
    /// `ExternalHoverOwnerCoordinator.callSetterAndRecordPending` already
    /// establishes (never a separate C call followed by a second pass
    /// that only hands the coordinator an already-minted token — that
    /// would defeat the B0-6 lock-ordering fix this coordinator exists
    /// for). The setter lease itself is acquired just before this call and
    /// released immediately after, bounding it to the synchronous C call
    /// only.
    private func applySetter(using cache: ExternalHoverCandidateCache, request: ExternalHoverWorkRequest) async {
        // Checkpoint 3 (immediately before the setter call/cache commit).
        guard isCurrent(request, checkpoint: "beforeSetter") else { return }

#if DEBUG
        // Review B4: `rangesInScope`/`clickedCellContained` are cheap
        // geometric facts about `cache`'s ALREADY-resolved ranges,
        // computed here purely for human-readable diagnostics — never a
        // second accept/reject judgment (guard 1): the actual accept/
        // reject decision is `minted != nil`, made by the real setter
        // call/lease below, not by these booleans. These are host cache/
        // request-computed geometric preflight facts, distinct from
        // Ghostty's own live-pointer setter-instant verdict (`minted`) —
        // logged for interpretation only, never fed back into an accept/
        // reject decision.
        //
        // Review round2 B4: uses the injected `diagnosticsEnabled()`
        // (never the static `ExternalHoverDiagnosticsGate.isEnabled`
        // directly), matching `resolveFully`'s own gate and making this
        // testable the same way.
        func logSetter(outcome: String, reason: String) {
            guard diagnosticsEnabled() else { return }
            let rangesInScope = cache.ranges.allSatisfy { range in
                UInt32(range.row) >= cache.topRow && UInt32(range.row) < cache.topRow + cache.rowCount
            }
            let clickedCellContained = cache.ranges.contains { range in
                UInt32(range.row) == request.cell.row &&
                request.cell.column >= Int(range.startColumn) && request.cell.column < Int(range.endColumn)
            }
            logDebugEvent(
                "link.externalHover stage=setter surfaceSerial=\(request.surfaceSerial) event=\(request.requestGeneration) " +
                "rangeCount=\(cache.ranges.count) textBytes=\(cache.physicalRowsText.utf8.count) " +
                "scopeTopRow=\(cache.topRow) scopeRowCount=\(cache.rowCount) " +
                "rangesInScope=\(rangesInScope) clickedCellContained=\(clickedCellContained) " +
                "outcome=\(outcome) reason=\(reason)"
            )
        }
#endif

        guard let setterLease = await teardownCoordinator.acquireExternalHoverLease(
            lifetimeID: request.lifetimeID,
            surface: request.surface
        ) else {
            // Review B4: this early return used to be silent — the ONLY
            // rejection path with no log line at all, breaking the dogfood
            // grep contract's promise to show every setter outcome.
#if DEBUG
            logSetter(outcome: "rejected", reason: "leaseRefused")
#endif
            cachesByLifetime.removeValue(forKey: request.lifetimeID)
            return
        }
        let minted = request.coordinator.callSetterAndRecordPending(
            event: request.requestGeneration,
            path: cache.path
        ) {
            self.callSetter(
                setterLease, cache.topRow, cache.rowCount, cache.physicalRowsText, cache.ranges,
                request.requestGeneration
            )
        }
#if DEBUG
        // Review round2 additional clarification 2: every `stage=setter`
        // line now carries a `reason` — `none` for an accepted setter,
        // `ghosttyRejected` for Ghostty's own real-time reject (the ONE
        // rejection cause besides `leaseRefused` above) — closing the
        // schema gap where only the lease-refusal path had a `reason`
        // field at all.
        logSetter(outcome: minted != nil ? "accepted" : "rejected", reason: minted != nil ? "none" : "ghosttyRejected")
#endif
        // (C) diagnostics — "setter 直後" trigger (design v4 §3.4):
        // drains synchronously while `setterLease` is still held, so a
        // rejected setter's ring entry (or a `renderQueueFailed` entry
        // right after an accepted one) reaches the host log without
        // depending on any later render frame.
        drainAndLog(
            setterLease, lifetimeID: request.lifetimeID, surfaceSerial: request.surfaceSerial,
            coordinator: request.coordinator
        )
        await teardownCoordinator.releaseExternalHoverLease(setterLease)

        guard let minted else {
            // Setter rejected (stale token, ineligible, out of scope,
            // etc.) — the mailbox's pending/owner state for this
            // candidate is untouched (callSetterAndRecordPending never
            // wrote anything), but this cache entry must not survive: the
            // next eligible request must fully re-resolve rather than
            // re-present a candidate the setter has already refused once.
            cachesByLifetime.removeValue(forKey: request.lifetimeID)
            return
        }
        var committed = cache
        committed.activationToken = minted
        cachesByLifetime[request.lifetimeID] = committed
    }

    /// (C) diagnostics — review B2: whether `entry` is the terminal
    /// diagnostic entry for its `event` — either the first render-pass
    /// validation verdict for that activation (design v4's "first render
    /// invalid/valid" liveness requirement), or a post-accept
    /// `renderQueueFailed` setter-side failure. Used to release exactly
    /// this event's render demand, never "any entry drained".
    private func isTerminalDiagnosticsEntry(_ entry: ExternalHoverDiagEntryValue) -> Bool {
        if ExternalHoverDiagSourceValue(rawValue: entry.source) == .render, entry.firstForActivation {
            return true
        }
        if ExternalHoverDiagSourceValue(rawValue: entry.source) == .setter,
           ExternalHoverDiagReasonValue(rawValue: entry.reason) == .renderQueueFailed {
            return true
        }
        return false
    }

    /// (C) ExternalHover diagnostics — destructively drains up to
    /// `Self.diagnosticsDrainCapacity` entries via the injected
    /// `drainDiagnostics` closure, logs each one (DEBUG-only), and
    /// notifies `coordinator` of every terminal entry so it can release
    /// exactly the render demand THAT event armed (review B2). Gated by
    /// `diagnosticsEnabled` (review B1) — when off, does nothing at all:
    /// no ring drain, no array allocation, no terminal-entry notify, no
    /// dropped-count bookkeeping. Returns whether ANY entries were
    /// drained, kept for tests; production callers no longer use this to
    /// decide render-demand release (the coordinator does, per-event).
    @discardableResult
    private func drainAndLog(
        _ lease: ExternalHoverSurfaceLease,
        lifetimeID: RuntimeSurfaceLifetimeID,
        surfaceSerial: UInt64,
        coordinator: ExternalHoverOwnerCoordinator
    ) -> Bool {
        guard diagnosticsEnabled() else { return false }
        let (entries, droppedCumulative) = drainDiagnostics(lease, Self.diagnosticsDrainCapacity)
        for entry in entries where isTerminalDiagnosticsEntry(entry) {
            coordinator.noteDiagnosticsTerminalEntry(event: entry.event)
        }
        // (C) diagnostics — review B5: linearized against the SAME
        // baseline the teardown coordinator's final drain also reports
        // into, so neither path can ever re-report a delta the other
        // already reported. Computed even outside `#if DEBUG`, since the
        // tracker's own state must stay consistent regardless of whether
        // this build actually logs the resulting line.
        let droppedDelta = droppedCountTracker.reportAndComputeDelta(
            lifetimeID: lifetimeID, cumulative: droppedCumulative
        )
#if DEBUG
        for entry in entries {
            logDebugEvent("link.externalHover.diag " + entry.describeLine(surfaceSerial: surfaceSerial))
        }
        if droppedDelta > 0 {
            logDebugEvent(
                "link.externalHover stage=ghosttyDiag event=none aggregate=true droppedDelta=\(droppedDelta) surfaceSerial=\(surfaceSerial)"
            )
        }
#endif
        return !entries.isEmpty
    }

    /// (C) ExternalHover diagnostics — the "render 後" trigger (design v4
    /// §3.4): called from the main-actor frame-delivery handler while an
    /// `externalHoverDiagnostics` render demand is retained. Acquires its
    /// OWN just-in-time lease (never one held across this `await`), same
    /// discipline as every other C access this actor makes. Returns
    /// whether any entries were recovered, so the caller can release its
    /// render demand once a terminal entry has actually been seen — a
    /// `false` return (surface already torn down, or nothing to drain
    /// yet) means the caller should keep the demand retained and try
    /// again on the next delivered frame.
    public func drainForRenderTrigger(
        lifetimeID: RuntimeSurfaceLifetimeID,
        surface: ExternalHoverRenderTriggerSurface,
        surfaceSerial: UInt64,
        coordinator: ExternalHoverOwnerCoordinator
    ) async -> Bool {
        guard let lease = await teardownCoordinator.acquireExternalHoverLease(
            lifetimeID: lifetimeID,
            surface: surface.surface
        ) else { return false }
        let drained = drainAndLog(
            lease, lifetimeID: lifetimeID, surfaceSerial: surfaceSerial, coordinator: coordinator
        )
        await teardownCoordinator.releaseExternalHoverLease(lease)
        return drained
    }

    /// (B) wiring review Blocking 7 — the ONE shared withdrawal path.
    /// Resolver nil, setter rejection, Cmd release, selection/remote/
    /// ineligible, cwd change, visibility loss, and surface
    /// replacement/teardown all route here.
    ///
    /// NEVER calls `receiveTransition` — that is Ghostty's real
    /// `external_link_hover` action-callback entry point exclusively
    /// (Pass 2's `GHOSTTY_ACTION_EXTERNAL_LINK_HOVER` handler); synthesizing
    /// an `inactive` call here would misrepresent to the ack reducer that
    /// Ghostty itself sent one. `public` because Pass 2's AppKit wiring
    /// (a different module) calls this directly for every non-resolver
    /// invalidation trigger (Cmd release, selection, remote, cwd/scroll/
    /// resize, visibility loss, teardown) — `reason` is diagnostic only.
    public func withdrawCurrentCandidate(request: ExternalHoverWorkRequest, reason: String) async {
        // Review round3 B1: ONE snapshot for this whole call, matching
        // `resolveFully`'s own "one consistent snapshot" discipline —
        // both the (now-gated) `rememberSurfaceSerial` call and the
        // later no-token-but-still-drain guard read the SAME value rather
        // than calling `diagnosticsEnabled()` twice.
        let diagnosticsOn = diagnosticsEnabled()
        if diagnosticsOn {
            rememberSurfaceSerial(request)
        }
        // A stale request must not clear a newer owner — but (review B3)
        // this is NOT `currentnessVerdict`: the real Cmd-release path
        // publishes `eligible == false` as the very trigger for this
        // withdrawal, so the guard here must authorize on ineligible/
        // invisible snapshots rather than reject them.
        guard isAuthorizedForWithdrawal(request) else { return }

        let removedToken = cachesByLifetime.removeValue(forKey: request.lifetimeID)?.activationToken
        let removedOwner = request.coordinator.withdrawUnconditionally()
        let tokenToClear = removedToken ?? removedOwner?.token

        // (C) diagnostics — review round2 B3: the real Cmd-release
        // production order lets `ghostty_surface_mouse_pos`-triggered
        // input-time invalidation (the native inactive-transition/
        // `noteExternalInactive` path) clear the cache and mailbox token
        // BEFORE this async withdrawal ever runs, so `tokenToClear == nil`
        // here is a legitimate outcome, not proof there is nothing left to
        // recover — a diagnostic entry can still be sitting in the ring
        // with no other trigger left to reach it. Only skip the
        // lease/drain entirely when there is truly nothing to do: no token
        // AND diagnostics off (so `drainAndLog` would no-op anyway).
        guard tokenToClear != nil || diagnosticsOn else { return }

        guard let lease = await teardownCoordinator.acquireExternalHoverLease(
            lifetimeID: request.lifetimeID,
            surface: request.surface
        ) else { return }
        if let tokenToClear {
            callClear(lease, tokenToClear)
        }
        // (C) diagnostics — design v4 §8 drain-liveness requirement 3:
        // "Cmd release後、追加のmouseMovedなしにinput invalidation/最終entry
        // が回収される". `withdrawCurrentCandidate` is exactly what a Cmd
        // release calls (via `clearExternalHoverCandidate`) — piggybacks
        // on the lease this clear call already acquired rather than
        // introducing a fourth trigger. Runs even when there was no
        // `tokenToClear` above, since the race this fix closes is
        // precisely "the token is already gone but the ring entry isn't".
        drainAndLog(
            lease, lifetimeID: request.lifetimeID, surfaceSerial: request.surfaceSerial,
            coordinator: request.coordinator
        )
        await teardownCoordinator.releaseExternalHoverLease(lease)
    }

    /// A REAL `inactive` ack arrived (via the action-callback handler
    /// calling `receiveTransition`, wired in a later pass) for `token`.
    /// Non-blocking, cache-only: invalidates this lifetime's cache ONLY IF
    /// `token` still matches its `activationToken` — a core-side
    /// destructive invalidation the host didn't initiate must not be
    /// masked by a same-range cache hit reusing a token the render loop
    /// has already discarded (review Blocking 7's closing requirement).
    /// Never touches the mailbox — `receiveTransition` already did.
    /// Returns the underlying `Task` for deterministic tests; production
    /// callers discard it.
    @discardableResult
    public nonisolated func noteExternalInactive(
        lifetimeID: RuntimeSurfaceLifetimeID,
        token: HoverActivationTokenValue
    ) -> Task<Void, Never> {
        Task { await self.invalidateCacheIfTokenMatches(lifetimeID: lifetimeID, token: token) }
    }

    private func invalidateCacheIfTokenMatches(
        lifetimeID: RuntimeSurfaceLifetimeID,
        token: HoverActivationTokenValue
    ) {
        guard cachesByLifetime[lifetimeID]?.activationToken == token else { return }
        cachesByLifetime.removeValue(forKey: lifetimeID)
    }

    /// Surface replacement/teardown: closes `lifetimeID` (a monotonic
    /// tombstone, never reopened — a NEW lifetime for the same surfaceID
    /// gets its own fresh entry, never this one) and drops its cache. A
    /// request for this lifetime already in the actor's queue becomes a no-op
    /// via `isCurrent`'s `closedLifetimes` check.
    ///
    /// The tombstones intentionally remain for the process lifetime.
    /// `RuntimeSurfaceLifetimeID` is a 24-byte value; allowing for `Set`
    /// storage overhead, budget about 48 bytes per entry, so even 10,000
    /// closed lifetimes retain only about 0.5 MB. Do not reclaim entries in
    /// the final drain or evict them at a size limit: either can reopen the
    /// same stale-request hole from round 1 Blocking 5.
    /// `ExternalHoverMailbox.teardown()` clears `pending` but does not seal
    /// the mailbox, so a queued request can subsequently reach
    /// `callSetterAndRecordPending` and recreate `pending` after a tombstone
    /// is removed. Safe reclamation is deferred in full to issue #9872,
    /// whose seven review items are the exit criteria:
    /// https://github.com/manaflow-ai/cmux/issues/9872
    /// Review context:
    /// https://github.com/manaflow-ai/cmux/pull/9868#discussion_r3751442728
    @discardableResult
    public nonisolated func invalidateSurface(_ lifetimeID: RuntimeSurfaceLifetimeID) -> Task<Void, Never> {
        let task = Task { await self.closeLifetime(lifetimeID) }
        teardownCoordinator.retainExternalHoverInvalidationTask(task, for: lifetimeID)
        return task
    }

    private func closeLifetime(_ lifetimeID: RuntimeSurfaceLifetimeID) {
        closedLifetimes.insert(lifetimeID)
        cachesByLifetime.removeValue(forKey: lifetimeID)
        // review non-blocking N2 — deliberately does NOT clear
        // `droppedCountTracker`'s entry for `lifetimeID` here: this
        // actor's `invalidateSurface` and the teardown coordinator's own
        // final drain are two independently-scheduled fire-and-forget
        // Tasks with no ordering between them (both are triggered
        // separately off `GhosttyNSView`'s teardown, never awaited
        // against each other), so whichever runs first must not
        // invalidate the baseline the other still needs. The teardown
        // coordinator's own final drain — which IS provably the very
        // last possible report for this lifetime, since the surface is
        // freed immediately after it runs — is where that cleanup
        // actually belongs; see `TerminalSurfaceRuntimeTeardownCoordinator
        // .defaultDrainExternalHoverDiagnostics`.
    }
}
