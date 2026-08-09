import CMUXDebugLog
import Foundation
import GhosttyKit
import os
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@Suite struct ExternalHoverWorkServiceTests {
    // Fixture shared by most tests: clicked row 5 (nonzero, and topRow=4 !=
    // clickedRow=5 — the exact "topRow != clickedRow" / nonzero viewport
    // offset shape review Blocking 6 flagged as at risk of a 1-row
    // conflation). previousRow (row 4) supplies the `.previous` fragment;
    // nextRow (row 6) is empty, so only `.previous` resolves.
    private static let existingPath = "/Users/dev/project/very-long-directory-name/file.txt"
    private static let previousRowText = "/Users/dev/project/very-long-directory-name/"
    private static let clickedRowText = "file.txt"
    private static let physicalRowsText = previousRowText + "\n" + clickedRowText + "\n"

    private static func makeLifetime(_ generation: UInt64 = 1) -> RuntimeSurfaceLifetimeID {
        .init(surfaceID: UUID(), runtimeSurfaceGeneration: generation)
    }

    private static func makeCoordinator(
        onProject: @escaping (ExternalHoverMailbox.Entry?) -> Void = { _ in },
        manageDiagnosticsRenderDemand: @escaping (Bool) -> Void = { _ in },
        diagnosticsEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> ExternalHoverOwnerCoordinator {
        ExternalHoverOwnerCoordinator(
            scheduler: { $0() },
            project: onProject,
            manageDiagnosticsRenderDemand: manageDiagnosticsRenderDemand,
            diagnosticsEnabled: diagnosticsEnabled
        )
    }

    private final class CallCounts: @unchecked Sendable {
        var reads = 0
        var setterCalls = 0
        var clearCalls = 0
        var clearedTokens: [HoverActivationTokenValue] = []
        // (C) diagnostics — the exact `hostEventID` each `callSetter`
        // invocation received, so a test can assert a rejected setter
        // and a later render-triggered drain were attributed to the
        // SAME event.
        var setterHostEventIDs: [UInt64] = []
        var drainCalls = 0
        var drainedLifetimeSurfaces: [RuntimeSurfaceLifetimeID] = []
        // Review round3 B3: how many times the injected
        // `readMetricsCalculator` actually ran — the observable proxy for
        // "gate OFF ⇒ zero metric computation", since a plain log-absence
        // assertion can't distinguish "never computed" from "computed
        // then discarded before logging".
        var metricsCalls = 0
        var lastMetrics: ExternalHoverReadMetrics?
    }

    private func makeRequest(
        lifetimeID: RuntimeSurfaceLifetimeID,
        mirror: HoverCallbackMirror,
        coordinator: ExternalHoverOwnerCoordinator,
        surface: ghostty_surface_t,
        cell: ExternalHoverGridCell,
        requestGeneration: UInt64,
        surfaceSerial: UInt64 = 0
    ) -> ExternalHoverWorkRequest {
        .init(
            lifetimeID: lifetimeID,
            surface: surface,
            requestGeneration: requestGeneration,
            cell: cell,
            viewportRowCount: 10,
            cwd: "/tmp",
            mirror: mirror,
            coordinator: coordinator,
            surfaceSerial: surfaceSerial
        )
    }

    /// (C) diagnostics — a deterministic drain double: `entriesToReturn`
    /// is drained exactly once (subsequent calls return empty), and
    /// `droppedCountCumulative` is whatever the test configures — tests
    /// that need to observe delta-across-drains configure a
    /// `@Sendable` mutable box themselves rather than using this
    /// convenience.
    private func makeService(
        teardownCoordinator: TerminalSurfaceRuntimeTeardownCoordinator,
        counts: CallCounts,
        onRead: (@Sendable () -> Void)? = nil,
        setterResult: HoverActivationTokenValue? = HoverActivationTokenValue(bits: (1, 1, 1, 1)),
        drainDiagnostics: @escaping ExternalHoverWorkService.DrainDiagnostics = { _, _ in (entries: [], droppedCountCumulative: 0) },
        // (C) diagnostics — review B1: `true` here (not the real host
        // gate) is deliberate. Every OTHER test in this suite exercises
        // the ring/demand pipeline itself and asserts on its behavior, so
        // it needs the gate forced on regardless of the real
        // `CMUX_EXTERNAL_HOVER_DIAGNOSTICS` env var (never set for `swift
        // test`). The one test that wants the REAL gate (proving
        // production's default composition does nothing when it's off)
        // constructs `ExternalHoverWorkService` directly instead of
        // through this helper.
        diagnosticsEnabled: @escaping ExternalHoverWorkService.DiagnosticsEnabled = { true },
        // Review round3 B3: counts real invocations while still
        // delegating to the REAL computation (`defaultReadMetrics`) — a
        // synthetic stand-in would prove nothing about the real formula.
        readMetricsCalculator: @escaping ExternalHoverWorkService.ReadMetricsCalculator = { text in
            ExternalHoverWorkService.defaultReadMetrics(text)
        }
    ) -> ExternalHoverWorkService {
        ExternalHoverWorkService(
            teardownCoordinator: teardownCoordinator,
            resolver: TerminalPathResolver(fileExists: { $0 == Self.existingPath }),
            readPhysicalRows: { _, _, _ in
                counts.reads += 1
                onRead?()
                return Self.physicalRowsText
            },
            callSetter: { _, _, _, _, _, hostEventID in
                counts.setterCalls += 1
                counts.setterHostEventIDs.append(hostEventID)
                return setterResult
            },
            callClear: { _, token in
                counts.clearCalls += 1
                counts.clearedTokens.append(token)
            },
            drainDiagnostics: { lease, capacity in
                counts.drainCalls += 1
                counts.drainedLifetimeSurfaces.append(lease.lifetimeID)
                return drainDiagnostics(lease, capacity)
            },
            diagnosticsEnabled: diagnosticsEnabled,
            readMetricsCalculator: { text in
                counts.metricsCalls += 1
                let metrics = readMetricsCalculator(text)
                counts.lastMetrics = metrics
                return metrics
            }
        )
    }

    /// Review round2 B4 completion condition #5's observable: `logRead`/
    /// `logResolve`/`logSetter` write through the REAL `DebugEventLog`
    /// sink (`logDebugEvent`), whose append queue is serial/FIFO — a
    /// sentinel logged AFTER the actions under test is therefore
    /// guaranteed to land on disk strictly after whatever those actions
    /// wrote, once the sentinel itself is observed. Bounded poll, never a
    /// fixed `sleep`.
    private static func waitForLogSentinel(
        _ sentinel: String, timeout: Duration = .seconds(2)
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let contents = try? String(contentsOfFile: DebugEventLog.currentLogPath(), encoding: .utf8),
               contents.contains(sentinel) {
                return contents
            }
            if ContinuousClock.now >= deadline {
                struct TimedOutWaitingForSentinel: Error {}
                throw TimedOutWaitingForSentinel()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func previousDirectionMaterializesRowsWithoutOffByOneAtNonzeroViewportOffset() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let service = makeService(teardownCoordinator: coordinator, counts: counts)

        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let mailboxCoordinator = Self.makeCoordinator()

        // Clicked row is 5 (nonzero, and the read window's topRow=4 !=
        // clickedRow — the exact shape review Blocking 6 flagged as at
        // risk of a 1-row conflation for the `.previous` direction, whose
        // fragment lives on the row ABOVE the clicked one).
        let request = makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )
        await service.submit(request).value

        #expect(mailboxCoordinator.currentMailbox.pending?.path == Self.existingPath)
        let cache = await service.debugCache(for: lifetimeID)
        #expect(cache?.topRow == 4)
        #expect(cache?.rowCount == 3)
        // Absolute viewport ranges: the clicked token ("file.txt") at row 5
        // (the clicked row itself, offset 0), and the winning `.previous`
        // fragment at row 4 — ONE ROW ABOVE, never row 5 or row 6, which is
        // exactly the conflation review Blocking 6 warned about.
        #expect(cache?.ranges.contains(
            ExternalHoverCellRangeValue(row: 5, startColumn: 0, endColumn: UInt16(Self.clickedRowText.count))
        ) == true)
        #expect(cache?.ranges.contains(
            ExternalHoverCellRangeValue(row: 4, startColumn: 0, endColumn: UInt16(Self.previousRowText.count))
        ) == true)
    }

    @Test func sameRangeCacheReuseSkipsResolverAndReadWhenCellStaysWithinCachedRanges() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let service = makeService(teardownCoordinator: coordinator, counts: counts)

        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let mailboxCoordinator = Self.makeCoordinator()

        // First move: column 0 of "file.txt", clicked token spans [0, 8).
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value
        #expect(counts.reads == 1)

        // Second move: column 5, still within the SAME clicked-token span —
        // must reuse the cache, never re-read or re-resolve.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 2, eligible: true, visible: true))
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 5), requestGeneration: 2
        )).value
        #expect(counts.setterCalls == 2)
        #expect(counts.reads == 1, "same-range cell move must not re-read physical rows")
    }

    @Test func aRequestThatGoesStaleMidFlightNeverCallsSetterOrCommitsCache() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let mailboxCoordinator = Self.makeCoordinator()

        // Deterministically models "a newer event arrived while this
        // request's read was in flight" WITHOUT real concurrency: the read
        // closure itself advances the mirror past this request's own
        // generation before returning — exactly what a genuinely-raced
        // newer main-thread event would have done by the time this
        // request's next acceptance-boundary check runs.
        let service = makeService(teardownCoordinator: coordinator, counts: counts, onRead: {
            mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 2, eligible: true, visible: true))
        })

        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value

        #expect(counts.setterCalls == 0)
        #expect(mailboxCoordinator.currentMailbox.acceptedOwner == nil)
        #expect(mailboxCoordinator.currentMailbox.pending == nil)
    }

    @Test func closedLifetimeNeverRebuildsCache() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let service = makeService(teardownCoordinator: coordinator, counts: counts)

        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let mailboxCoordinator = Self.makeCoordinator()

        await service.invalidateSurface(lifetimeID).value

        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value

        #expect(counts.setterCalls == 0)
        #expect(counts.reads == 0)
    }

    @Test func resolverNilTriggersSharedWithdrawalWithTheOldTokenExactlyOnce() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()

        // Toggle what the injected read returns: first a resolvable pair of
        // rows, then unresolvable text (no path anywhere).
        let returnResolvable = OSAllocatedUnfairLock(initialState: true)
        let service = ExternalHoverWorkService(
            teardownCoordinator: coordinator,
            resolver: TerminalPathResolver(fileExists: { $0 == Self.existingPath }),
            readPhysicalRows: { _, _, _ in
                counts.reads += 1
                return returnResolvable.withLock { $0 } ? Self.physicalRowsText : "\n\n\n"
            },
            callSetter: { _, _, _, _, _, hostEventID in
                counts.setterCalls += 1
                counts.setterHostEventIDs.append(hostEventID)
                return HoverActivationTokenValue(bits: (1, 1, 1, 1))
            },
            callClear: { _, token in
                counts.clearCalls += 1
                counts.clearedTokens.append(token)
            },
            drainDiagnostics: { lease, _ in
                counts.drainCalls += 1
                counts.drainedLifetimeSurfaces.append(lease.lifetimeID)
                return (entries: [], droppedCountCumulative: 0)
            }
        )

        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value

        // A DIFFERENT row (well outside the first candidate's cached
        // ranges) — the same-range cache reuse must not intercept this and
        // must genuinely re-resolve, which is what actually exercises the
        // "resolver nil" path this test is for.
        returnResolvable.withLock { $0 = false }
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 2, eligible: true, visible: true))
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 7, column: 0), requestGeneration: 2
        )).value

        #expect(counts.clearCalls == 1)
        #expect(counts.clearedTokens == [HoverActivationTokenValue(bits: (1, 1, 1, 1))])
        #expect(mailboxCoordinator.currentMailbox.acceptedOwner == nil)
    }

    @Test func setterRejectionInvalidatesTheCacheSoTheNextRequestFullyResolvesAgain() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let mailboxCoordinator = Self.makeCoordinator()

        let service = makeService(teardownCoordinator: coordinator, counts: counts, setterResult: nil)
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value
        #expect(mailboxCoordinator.currentMailbox.pending == nil)

        // Same cell again — since the setter rejected, the cache must NOT
        // have been kept; this must re-read/re-resolve, not silently no-op.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 2, eligible: true, visible: true))
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 2
        )).value

        #expect(counts.reads == 2)
        #expect(counts.setterCalls == 2)
    }

    @Test func staleWithdrawalRequestNeverClearsANewerOwner() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()
        let service = makeService(teardownCoordinator: coordinator, counts: counts)

        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 5, eligible: true, visible: true))
        let staleRequest = makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 5
        )

        // Mirror has since moved to a NEWER event (e.g. the pointer moved
        // again); a delayed withdrawal attempt for the stale generation 5
        // must be a complete no-op.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 6, eligible: true, visible: true))
        await service.withdrawCurrentCandidate(request: staleRequest, reason: "test.stale")

        #expect(counts.clearCalls == 0)
    }

    @Test func noteExternalInactiveInvalidatesCacheOnlyWhenTokenMatches() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let mailboxCoordinator = Self.makeCoordinator()
        let mintedToken = HoverActivationTokenValue(bits: (7, 7, 7, 7))
        let service = makeService(teardownCoordinator: coordinator, counts: counts, setterResult: mintedToken)

        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value

        // Mismatched token: a delayed/foreign inactive callback must not
        // touch this lifetime's live cache.
        await service.noteExternalInactive(
            lifetimeID: lifetimeID, token: HoverActivationTokenValue(bits: (9, 9, 9, 9))
        ).value

        // Same cell again: cache still valid (no re-read) proves the
        // mismatched inactive above did nothing.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 2, eligible: true, visible: true))
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 2
        )).value
        #expect(counts.reads == 1, "mismatched noteExternalInactive must not have invalidated the cache")

        // Matching token: this DOES invalidate the cache.
        await service.noteExternalInactive(lifetimeID: lifetimeID, token: mintedToken).value

        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 3, eligible: true, visible: true))
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 3
        )).value
        #expect(counts.reads == 2, "matching noteExternalInactive must have invalidated the cache")
    }

    // Pass 2 (impl-B-pass2-wiring) — deferred from Pass 1. The click path
    // (`prepareCommandClickContext`/`commitWrappedCandidate`/
    // `performCommandClickRelease`, untouched by this pass) shares only
    // the stateless `TerminalPathResolver` with (B) ExternalHover — never
    // this actor's cache or mailbox. This exercises that boundary
    // directly: prime the actor's cache with a candidate for one
    // (existing) path, then run a SEPARATE, freshly-constructed resolver
    // call — standing in for a click at a different cell/cwd, backed by a
    // `fileExists` double that reports the ORIGINAL cached path as
    // deleted — and confirm it resolves its own candidate exactly once,
    // from its own fresh filesystem check, with no path through the
    // actor's state at all (the two calls don't even share a resolver
    // instance).
    @Test func clickPathResolutionIsUnaffectedByAStaleOrDeletedHoverCache() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let mailboxCoordinator = Self.makeCoordinator()

        // 1. Prime the hover actor's cache for `existingPath`, as if the
        //    user had hovered it a moment ago.
        let service = makeService(teardownCoordinator: coordinator, counts: counts)
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value
        let primedCache = await service.debugCache(for: lifetimeID)
        #expect(primedCache?.path == Self.existingPath)

        // 2. The click path never touches `service`/`mirror`/
        //    `mailboxCoordinator` above — it only ever gets a fresh
        //    `TerminalPathResolver`, exactly as `commitWrappedCandidate`
        //    does. This double reports the hover-cached path as GONE
        //    (deleted since it was cached) and a DIFFERENT path — at a
        //    different cwd, standing in for a click at a different
        //    location — as the one that actually exists.
        let clickOnlyPath = "/Users/dev/other-project/click-target.txt"
        let clickResolveCount = OSAllocatedUnfairLock(initialState: 0)
        let clickResolver = TerminalPathResolver(fileExists: { path in
            clickResolveCount.withLock { $0 += 1 }
            return path == clickOnlyPath
        })
        // `cwd` here is deliberately NOT the click-only fixture's own
        // directory (mirroring the module fixture above, which resolves
        // via the absolute `previousRowText` join, never `cwd`) — so the
        // single-row `resolveVisibleLinePath` check inside
        // `wrappedPathSeed` genuinely fails first and the wrapped-join
        // path actually runs, instead of short-circuiting on a same-row
        // match before ever exercising the code this test targets.
        let previousRowText = "/Users/dev/other-project/"
        let clickedRowText = "click-target.txt"
        guard let seed = clickResolver.wrappedPathSeed(in: clickedRowText, column: 0, cwd: "/tmp") else {
            Issue.record("expected a wrapped-path seed for the click-only fixture")
            return
        }
        let resolution = clickResolver.resolveWrappedCandidate(
            seed: seed, previousRow: previousRowText, nextRow: nil, cwd: "/tmp"
        )

        #expect(resolution?.path == clickOnlyPath)
        #expect(clickResolveCount.withLock { $0 } > 0, "the click path must run its OWN fresh filesystem check")

        // 3. The hover actor's cache is exactly as it was before the
        //    click-path call ran — never read, never invalidated, never
        //    touched by it.
        let cacheAfterClick = await service.debugCache(for: lifetimeID)
        #expect(cacheAfterClick?.path == Self.existingPath)
        #expect(counts.reads == 1, "the click-path resolution above must not have gone through the hover actor's read closure")
    }

    // (C) ExternalHover diagnostics — design-hover-diagnostics-v4-final.md
    // §8's drain-liveness tests, plus supporting structured-reason/
    // droppedDelta unit tests. See each test's doc for which of the 6
    // required liveness scenarios it maps to; #3 (Cmd release) and part
    // of #2 (the Zig-side renderQueueFailed sub-case) are additionally
    // covered at the Zig unit level (`renderer/link.zig`'s
    // `ExternalHoverDiagRing`/`ExternalHover` tests) since there is no
    // lightweight `Surface` test fixture in this codebase to drive that
    // side end to end — the same convention `setExternalLinkHover`/
    // `clearExternalLinkHover` themselves already follow (zero direct
    // Zig tests; only their extractable pure pieces are tested).

    /// Drain liveness #1: "setter accepted → first render invalid →
    /// transition なし" — even with no further mouse/render activity, a
    /// direct render-trigger drain call must be able to reach whatever
    /// entries the ring is holding. Proves `drainForRenderTrigger` (the
    /// production render-trigger entry point `GhosttyNSView`'s frame
    /// delivery handler calls) genuinely reaches the drain closure and
    /// reports "entries recovered" — independent of any transition ever
    /// having arrived.
    @Test func drainForRenderTriggerRecoversEntriesWithNoTransitionOrFurtherInput() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        let service = makeService(
            teardownCoordinator: coordinator, counts: counts,
            drainDiagnostics: { _, _ in
                (
                    entries: [ExternalHoverDiagEntryValue(event: 1, source: 3, reason: 0, verdict: 4, flags: 1, seq: 0)],
                    droppedCountCumulative: 0
                )
            }
        )

        let drained = await service.drainForRenderTrigger(
            lifetimeID: lifetimeID, surface: ExternalHoverRenderTriggerSurface(surface), surfaceSerial: 7,
            coordinator: Self.makeCoordinator()
        )
        #expect(drained, "a render-trigger drain that finds entries must report they were recovered")
        #expect(counts.drainCalls == 1)
        #expect(counts.drainedLifetimeSurfaces == [lifetimeID])
    }

    /// A render-trigger drain that finds NOTHING must report `false` (so
    /// the caller keeps its render demand retained and tries again on
    /// the next frame) rather than silently looking identical to
    /// success.
    @Test func drainForRenderTriggerReportsFalseWhenNothingToRecoverYet() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let service = makeService(teardownCoordinator: coordinator, counts: counts)

        let drained = await service.drainForRenderTrigger(
            lifetimeID: lifetimeID, surface: ExternalHoverRenderTriggerSurface(surface), surfaceSerial: 1,
            coordinator: Self.makeCoordinator()
        )
        #expect(!drained)
    }

    /// Drain liveness #2 (Swift-side half): a rejected setter call and an
    /// accepted one both thread the SAME `hostEventID` (== the request's
    /// own `requestGeneration`) into `callSetter` — the precondition that
    /// makes "reject reason and a post-accept `renderQueueFailed`
    /// side-failure are attributable to the same `(surfaceSerial, event)`"
    /// hold on the Zig side (both branches read the identical
    /// `host_event_id` C parameter — see `Surface.setExternalLinkHover`).
    @Test func setterCallAlwaysReceivesTheRequestsOwnEventIDRegardlessOfAcceptOrReject() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()

        // Accepted case.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 42, eligible: true, visible: true))
        let acceptingService = makeService(teardownCoordinator: coordinator, counts: counts, setterResult: HoverActivationTokenValue(bits: (1, 1, 1, 1)))
        await acceptingService.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 42
        )).value
        #expect(counts.setterHostEventIDs == [42])

        // Rejected case, same request generation semantics — a fresh
        // lifetime avoids the same-range cache short-circuit.
        let secondLifetime = Self.makeLifetime()
        mirror.publish(.init(lifetimeID: secondLifetime, hoverEventID: 99, eligible: true, visible: true))
        let rejectingCounts = CallCounts()
        let rejectingService = makeService(teardownCoordinator: coordinator, counts: rejectingCounts, setterResult: nil)
        await rejectingService.submit(makeRequest(
            lifetimeID: secondLifetime, mirror: mirror, coordinator: Self.makeCoordinator(),
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 99
        )).value
        #expect(rejectingCounts.setterHostEventIDs == [99])
    }

    /// Drain liveness #4: two different lifetimes (standing in for two
    /// surfaces) that happen to share the exact same `requestGeneration`
    /// ("event") value never cross-contaminate each other's cache,
    /// dropped-count bookkeeping, or drain attribution.
    @Test func twoLifetimesSharingTheSameEventValueNeverMixLifecycles() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeA = Self.makeLifetime()
        let lifetimeB = Self.makeLifetime()
        let surfaceA = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let surfaceB = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surfaceA.deallocate(); surfaceB.deallocate() }
        let mirrorA = HoverCallbackMirror()
        let mirrorB = HoverCallbackMirror()
        let coordinatorA = Self.makeCoordinator()
        let coordinatorB = Self.makeCoordinator()

        // Both surfaces' event counters happen to read the same value —
        // exactly the collision design v4 §1 says `surfaceSerial` exists
        // to disambiguate in the LOG, but the actor's own per-lifetime
        // keying must already be immune to it regardless of logging.
        mirrorA.publish(.init(lifetimeID: lifetimeA, hoverEventID: 5, eligible: true, visible: true))
        mirrorB.publish(.init(lifetimeID: lifetimeB, hoverEventID: 5, eligible: true, visible: true))

        let service = makeService(
            teardownCoordinator: coordinator, counts: counts,
            drainDiagnostics: { lease, _ in
                // Distinct cumulative dropped counts per lifetime, so a
                // cross-contaminated `previousDroppedCountByLifetime` key
                // would show up as one lifetime observing the other's value.
                let cumulative: UInt64 = lease.lifetimeID == lifetimeA ? 3 : 11
                return (entries: [], droppedCountCumulative: cumulative)
            }
        )

        await service.submit(makeRequest(
            lifetimeID: lifetimeA, mirror: mirrorA, coordinator: coordinatorA,
            surface: surfaceA, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 5
        )).value
        await service.submit(makeRequest(
            lifetimeID: lifetimeB, mirror: mirrorB, coordinator: coordinatorB,
            surface: surfaceB, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 5
        )).value

        let cacheA = await service.debugCache(for: lifetimeA)
        let cacheB = await service.debugCache(for: lifetimeB)
        #expect(cacheA?.path == Self.existingPath)
        #expect(cacheB?.path == Self.existingPath)
        #expect(await service.debugPreviousDroppedCount(for: lifetimeA) == 3)
        #expect(await service.debugPreviousDroppedCount(for: lifetimeB) == 11)
    }

    /// Drain liveness #5: ring overflow's `droppedDelta` is derived
    /// against the PREVIOUS drain's cumulative value, so an unchanged
    /// cumulative count across two consecutive drains reports zero new
    /// drops the second time — a missing/dropped entry is never
    /// misread as "nothing was ever dropped" (no entries + no delta
    /// looking identical to "fully caught up"), and an already-reported
    /// drop batch is never re-reported.
    @Test func droppedCountIsTrackedPerLifetimeAndOnlyGrowsOnGenuinelyNewDrops() async {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        let cumulative = OSAllocatedUnfairLock(initialState: UInt64(3))
        let service = makeService(
            teardownCoordinator: coordinator, counts: counts,
            drainDiagnostics: { _, _ in (entries: [], droppedCountCumulative: cumulative.withLock { $0 }) }
        )

        let demandCoordinator = Self.makeCoordinator()
        _ = await service.drainForRenderTrigger(
            lifetimeID: lifetimeID, surface: ExternalHoverRenderTriggerSurface(surface), surfaceSerial: 1,
            coordinator: demandCoordinator
        )
        #expect(await service.debugPreviousDroppedCount(for: lifetimeID) == 3)

        // No NEW drops between drains — the ring's cumulative value is
        // unchanged.
        _ = await service.drainForRenderTrigger(
            lifetimeID: lifetimeID, surface: ExternalHoverRenderTriggerSurface(surface), surfaceSerial: 1,
            coordinator: demandCoordinator
        )
        #expect(await service.debugPreviousDroppedCount(for: lifetimeID) == 3, "an unchanged cumulative count must not be re-added")

        // A genuinely new overflow batch bumps the cumulative value —
        // the tracked previous value must advance to match, not stay
        // pinned at the old one.
        cumulative.withLock { $0 = 9 }
        _ = await service.drainForRenderTrigger(
            lifetimeID: lifetimeID, surface: ExternalHoverRenderTriggerSurface(surface), surfaceSerial: 1,
            coordinator: demandCoordinator
        )
        #expect(await service.debugPreviousDroppedCount(for: lifetimeID) == 9)
    }

    /// Structured-reason/currentness classification: `CurrentnessVerdict`
    /// independently distinguishes every drop reason design v4 §6.1
    /// requires — never collapsing them into one generic "stale" outcome
    /// — from a SINGLE mirror snapshot capture, matching the guard's own
    /// decision exactly (the same call this test makes is what
    /// `isCurrent` uses internally).
    @Test func currentnessVerdictClassifiesEachDropReasonIndependently() async {
        let lifetimeID = Self.makeLifetime()
        let otherLifetime = Self.makeLifetime()
        let mirror = HoverCallbackMirror()
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let mailboxCoordinator = Self.makeCoordinator()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let counts = CallCounts()
        let service = makeService(teardownCoordinator: coordinator, counts: counts)

        func request(generation: UInt64) -> ExternalHoverWorkRequest {
            makeRequest(
                lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
                surface: surface, cell: ExternalHoverGridCell(row: 0, column: 0), requestGeneration: generation
            )
        }

        // Lifetime mismatch: mirror published for a DIFFERENT lifetime.
        mirror.publish(.init(lifetimeID: otherLifetime, hoverEventID: 1, eligible: true, visible: true))
        var verdict = await service.currentnessVerdict(request(generation: 1))
        #expect(verdict == .dropped(reason: "lifetimeMismatch"))

        // Event mismatch: right lifetime, stale generation.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 2, eligible: true, visible: true))
        verdict = await service.currentnessVerdict(request(generation: 1))
        #expect(verdict == .dropped(reason: "eventMismatch"))

        // Ineligible.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: false, visible: true))
        verdict = await service.currentnessVerdict(request(generation: 1))
        #expect(verdict == .dropped(reason: "ineligible"))

        // Not visible.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: false))
        verdict = await service.currentnessVerdict(request(generation: 1))
        #expect(verdict == .dropped(reason: "notVisible"))

        // Closed lifetime — checked before the mirror at all.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        await service.invalidateSurface(lifetimeID).value
        verdict = await service.currentnessVerdict(request(generation: 1))
        #expect(verdict == .dropped(reason: "closedLifetime"))

        // Everything matches (a fresh lifetime, since the one above is
        // now permanently closed): current.
        let freshLifetime = Self.makeLifetime()
        mirror.publish(.init(lifetimeID: freshLifetime, hoverEventID: 1, eligible: true, visible: true))
        let freshRequest = makeRequest(
            lifetimeID: freshLifetime, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 0, column: 0), requestGeneration: 1
        )
        verdict = await service.currentnessVerdict(freshRequest)
        #expect(verdict == .current)
    }

    // MARK: - Code-fix review (B1/B2/B3)

    /// Review B1: with the REAL production composition — neither the
    /// coordinator's nor the service's `diagnosticsEnabled` overridden,
    /// both defaulting to `ExternalHoverDiagnosticsGate.isEnabled`, which
    /// is always `false` in a `swift test` process since
    /// `CMUX_EXTERNAL_HOVER_DIAGNOSTICS` is never set for it — a
    /// successful setter call must retain ZERO render demand, and a drain
    /// (whether piggybacked on the setter or triggered by a render frame)
    /// must make ZERO calls into the injected `drainDiagnostics` closure:
    /// design v4 §7 guard 4's "gate OFF ⇒ no allocation/ring/demand work",
    /// via the injectable seam rather than a hardcoded check that would
    /// defeat testability. The setter call itself must still run — only
    /// the diagnostics side effects are gated.
    @Test func gateOffProductionDefaultCompositionArmsNoDemandAndDrainsNothing() async {
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))

        final class DemandCalls: @unchecked Sendable {
            var values: [Bool] = []
        }
        let demandCalls = DemandCalls()
        // No `diagnosticsEnabled` override on either type below — the
        // REAL default composition, matching production wiring exactly.
        let mailboxCoordinator = ExternalHoverOwnerCoordinator(
            scheduler: { $0() },
            project: { _ in },
            manageDiagnosticsRenderDemand: { active in demandCalls.values.append(active) }
        )
        let service = ExternalHoverWorkService(
            teardownCoordinator: teardownCoordinator,
            resolver: TerminalPathResolver(fileExists: { $0 == Self.existingPath }),
            readPhysicalRows: { _, _, _ in
                counts.reads += 1
                return Self.physicalRowsText
            },
            callSetter: { _, _, _, _, _, hostEventID in
                counts.setterCalls += 1
                counts.setterHostEventIDs.append(hostEventID)
                return HoverActivationTokenValue(bits: (1, 1, 1, 1))
            },
            callClear: { _, token in
                counts.clearCalls += 1
                counts.clearedTokens.append(token)
            },
            drainDiagnostics: { lease, capacity in
                counts.drainCalls += 1
                counts.drainedLifetimeSurfaces.append(lease.lifetimeID)
                return (entries: [], droppedCountCumulative: 0)
            }
        )

        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )).value

        #expect(counts.setterCalls == 1, "the setter itself must still run regardless of the diagnostics gate")
        #expect(demandCalls.values.isEmpty, "gate OFF must never retain/release render demand")
        #expect(counts.drainCalls == 0, "gate OFF must never call into the drain closure at all")

        _ = await service.drainForRenderTrigger(
            lifetimeID: lifetimeID, surface: ExternalHoverRenderTriggerSurface(surface), surfaceSerial: 1,
            coordinator: mailboxCoordinator
        )
        #expect(counts.drainCalls == 0, "gate OFF must never drain on the render-trigger path either")
    }

    /// Review round2 B4 — completion condition #5: with the injected gate
    /// ON, `resolveFully`'s `stage=read` line must appear via the REAL
    /// `DebugEventLog` sink carrying the exact `newlineCount`/
    /// `rawEntryCount`/`expectedRows` this fixture's text implies (also
    /// covers additional clarification 1: `expectedRows` restored
    /// alongside `topRow`/`rowCount`); with the gate OFF, NO such line
    /// appears at all, which is the observable proxy for "the metric
    /// computation behind it never ran either" (both live inside the
    /// SAME `if diagnosticsOn` block in `resolveFully`, so one cannot
    /// happen without the other).
    ///
    /// Before this fix, `logRead`'s own internal guard checked the
    /// STATIC `ExternalHoverDiagnosticsGate.isEnabled` (always `false` in
    /// a `swift test` process) instead of the actor's injected
    /// `diagnosticsEnabled`, so an injected `{ true }` here would have
    /// produced NO line at all — exactly the "static vs. injected gate
    /// mixing" the review flagged, and exactly why this test fails
    /// against the pre-fix code.
    @Test func gateOnEmitsTheExactReadMetricsGateOffEmitsNoLineAtAll() async throws {
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()

        // `Self.physicalRowsText` is `previousRowText + "\n" + clickedRowText
        // + "\n"` — exactly 2 newlines, so a bare `omittingEmptySubsequences:
        // false` split would yield 3 raw entries.
        let expectedNewlineCount = 2
        let expectedRawEntryCount = 3

        func run(diagnosticsOn: Bool, surfaceSerial: UInt64, requestGeneration: UInt64) async {
            let lifetimeID = Self.makeLifetime()
            let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
            defer { surface.deallocate() }
            mirror.publish(.init(
                lifetimeID: lifetimeID, hoverEventID: requestGeneration, eligible: true, visible: true
            ))
            let service = makeService(
                teardownCoordinator: teardownCoordinator, counts: counts,
                diagnosticsEnabled: { diagnosticsOn }
            )
            await service.submit(makeRequest(
                lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
                surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0),
                requestGeneration: requestGeneration, surfaceSerial: surfaceSerial
            )).value
        }

        // Distinctive, effectively-unique markers so a substring search
        // can never be confused with another test's or a stale run's line.
        let startSentinel = "cmux-test-start-\(UUID().uuidString)"
        let onSerial: UInt64 = 987_654_321
        let onEvent: UInt64 = 111_222_333
        let offSerial: UInt64 = 987_654_322
        let offEvent: UInt64 = 111_222_334
        let endSentinel = "cmux-test-end-\(UUID().uuidString)"

        logDebugEvent(startSentinel)
        await run(diagnosticsOn: true, surfaceSerial: onSerial, requestGeneration: onEvent)
        await run(diagnosticsOn: false, surfaceSerial: offSerial, requestGeneration: offEvent)
        logDebugEvent(endSentinel)

        let contents = try await Self.waitForLogSentinel(endSentinel)
        guard let startRange = contents.range(of: startSentinel),
              let endRange = contents.range(of: endSentinel) else {
            Issue.record("expected both sentinels to be present in the log file")
            return
        }
        let window = contents[startRange.upperBound..<endRange.lowerBound]

        let onLinePrefix = "stage=read surfaceSerial=\(onSerial) event=\(onEvent)"
        guard let onLine = window.components(separatedBy: "\n").first(where: { $0.contains(onLinePrefix) }) else {
            Issue.record("expected a stage=read line for surfaceSerial=\(onSerial) event=\(onEvent) with gate ON")
            return
        }
        #expect(onLine.contains("outcome=accepted"), "the fixture resolves successfully, so this must be the accepted line")
        #expect(onLine.contains("expectedRows="), "additional clarification 1: expectedRows must be present alongside topRow/rowCount")
        #expect(
            onLine.contains("newlineCount=\(expectedNewlineCount)"),
            "the fixture's physicalRowsText has exactly \(expectedNewlineCount) newlines"
        )
        #expect(
            onLine.contains("rawEntryCount=\(expectedRawEntryCount)"),
            "rawEntryCount must be newlineCount + 1, derived without allocating an array"
        )
        #expect(
            onLine.contains("textBytes=\(Self.physicalRowsText.utf8.count)"),
            "textBytes must be the real read text's byte count"
        )
        #expect(
            !window.contains("surfaceSerial=\(offSerial)"),
            "gate OFF must never emit a stage=read line — the same branch that would compute its metrics never runs"
        )
    }

    /// Review B2: render demand must be armed BEFORE `setterCall` runs —
    /// not after `callSetterAndRecordPending` returns — since Ghostty's
    /// real setter triggers `queueRender()` synchronously from inside the
    /// C call itself. Models that synchronous in-setter render trigger
    /// directly: the injected `setterCall` closure records its own
    /// position in the SAME order log the demand closure writes to, so
    /// this pins the actual ordering rather than merely the end state.
    /// Review round2 B1: the earlier version of this test injected a
    /// synchronous recorder closure for `manageDiagnosticsRenderDemand`,
    /// which never exercised the real async/sync boundary production
    /// callers cross — `GhosttyNSView` used to hop
    /// `DispatchQueue.main.async` before touching its render-demand
    /// retention, so the renderer-thread-visible counter could still read
    /// `isActive == false` well after `callSetterAndRecordPending`
    /// returned, exactly when Ghostty's synchronous in-setter
    /// `queueRender()` needed it already retained. This version wires the
    /// REAL `RenderDemandActivationTracker` + `RenderDemandCounter` pair
    /// (the same types `GhosttyNSView` holds) behind the coordinator's
    /// `manageDiagnosticsRenderDemand` closure, using the identical
    /// one-line synchronous delegate production now uses, and asserts the
    /// counter is already `isActive` from INSIDE the setter closure —
    /// before `callSetterAndRecordPending` has returned. Reintroducing an
    /// async hop in that closure would leave `isActive == false` at this
    /// point (nothing pumps a run loop synchronously in a unit test), so
    /// this test fails exactly the way the review's counterexample
    /// describes if the regression comes back.
    /// Review round3 B2: the earlier version of this test built its own
    /// `manageDiagnosticsRenderDemand: { active in tracker.setActive(active) }`
    /// closure literal — a one-liner that happens to match production's
    /// own, but production and test each wrote it independently, so
    /// nothing stops `GhosttyNSView`'s copy from drifting back to a
    /// `DispatchQueue.main.async` hop while this test stays green. This
    /// version goes through `RenderDemandActivationTracker
    /// .makeExternalHoverOwnerCoordinator` — the SAME factory
    /// `GhosttyNSView.externalHoverOwnerCoordinator` is built from — so a
    /// regression in that ONE shared function fails both the app and
    /// this test identically.
    @Test func productionCompositionKeepsTheRenderDemandTrackerActiveInsideTheSetterClosureNotAfterItReturns() {
        let tracker = RenderDemandActivationTracker()
        let coordinator = tracker.makeExternalHoverOwnerCoordinator(
            scheduler: { $0() },
            project: { _ in },
            diagnosticsEnabled: { true }
        )
        var isActiveInsideSetterClosure = false
        let token = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") {
            isActiveInsideSetterClosure = tracker.counter.isActive
            return HoverActivationTokenValue(bits: (1, 1, 1, 1))
        }
        #expect(token != nil)
        #expect(
            isActiveInsideSetterClosure,
            "renderer-thread-visible demand must already be active by the time Ghostty's synchronous setter can queueRender(), not on some later async turn"
        )
        #expect(tracker.counter.isActive, "demand stays retained after the setter call returns too")
    }

    /// Review round3 B1 + B3 (folded into one test per the review's own
    /// instruction): gate OFF must perform ZERO diagnostics-only work —
    /// neither registering this request's `surfaceSerial` into
    /// `surfaceSerialRegistry` (a dictionary write + lock that exists
    /// purely for diagnostics correlation, design v4 §7 guard 4) NOR
    /// invoking the read-metrics calculator — and gate ON must invoke the
    /// calculator EXACTLY once with the REAL computed values (not merely
    /// "a log line is absent/present", which can't distinguish "never
    /// computed" from "computed then discarded before logging" — the
    /// exact regression this review flagged as undetectable by the
    /// previous test).
    @Test func gateOffPerformsNoDiagnosticsOnlyWorkGateOnComputesMetricsExactlyOnceWithRealValues() async {
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()
        final class GateBox: @unchecked Sendable { var on = false }
        let gate = GateBox()
        let service = makeService(
            teardownCoordinator: teardownCoordinator, counts: counts,
            diagnosticsEnabled: { gate.on }
        )

        // Gate OFF.
        let offLifetime = Self.makeLifetime()
        let offSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { offSurface.deallocate() }
        mirror.publish(.init(lifetimeID: offLifetime, hoverEventID: 1, eligible: true, visible: true))
        gate.on = false
        await service.submit(makeRequest(
            lifetimeID: offLifetime, mirror: mirror, coordinator: mailboxCoordinator,
            surface: offSurface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1,
            surfaceSerial: 111
        )).value
        #expect(counts.metricsCalls == 0, "gate OFF must never compute read metrics")
        #expect(
            teardownCoordinator.surfaceSerialRegistry.serial(for: offLifetime) == nil,
            "gate OFF must never register this lifetime's surfaceSerial either — it's diagnostics-only work"
        )

        // Gate ON.
        let onLifetime = Self.makeLifetime()
        let onSurface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { onSurface.deallocate() }
        mirror.publish(.init(lifetimeID: onLifetime, hoverEventID: 1, eligible: true, visible: true))
        gate.on = true
        await service.submit(makeRequest(
            lifetimeID: onLifetime, mirror: mirror, coordinator: mailboxCoordinator,
            surface: onSurface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1,
            surfaceSerial: 222
        )).value
        #expect(counts.metricsCalls == 1, "gate ON must compute read metrics exactly once for one request")
        #expect(
            counts.lastMetrics == ExternalHoverWorkService.defaultReadMetrics(Self.physicalRowsText),
            "the computed metrics must be the REAL values for this fixture's text, not a stand-in"
        )
        #expect(teardownCoordinator.surfaceSerialRegistry.serial(for: onLifetime) == 222)
    }

    /// Review round2 B2: the earlier version of this test manually
    /// injected A's own terminal entry via
    /// `noteDiagnosticsTerminalEntry(event: 1)` AFTER B's setter had
    /// already succeeded — an assumption that doesn't hold under
    /// Ghostty's real single-activation-per-surface semantics.
    /// `renderer_state.mouse.external_hover` holds exactly ONE
    /// active/pending override per surface: once B's setter call mints a
    /// new token for the SAME surface, A's own terminal ring entry will
    /// simply never be generated — there is no later event that could
    /// ever deliver it. This version models the real flow instead: A's
    /// setter succeeds, then (before any render) B's setter succeeds too
    /// — superseding A at the Ghostty layer — and only B's FIRST verdict
    /// ever arrives. Demand must still release once B reaches its own
    /// terminal entry, even though A's terminal entry never separately
    /// arrives; before the B2 fix, A's stale arm would have left
    /// `pendingDiagnosticsRenderEvents` non-empty forever and this
    /// `noteDiagnosticsTerminalEntry(event: 2)` alone would never release
    /// demand.
    @Test func supersedingSetterReleasesThePriorEventsDemandSoOnlyTheNewOnesTerminalEntryIsNeeded() {
        final class Order: @unchecked Sendable {
            var values: [Bool] = []
        }
        let order = Order()
        let coordinator = ExternalHoverOwnerCoordinator(
            scheduler: { $0() },
            project: { _ in },
            manageDiagnosticsRenderDemand: { active in order.values.append(active) },
            diagnosticsEnabled: { true }
        )
        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") {
            HoverActivationTokenValue(bits: (1, 1, 1, 1))
        }
        _ = coordinator.callSetterAndRecordPending(event: 2, path: "/tmp/b") {
            HoverActivationTokenValue(bits: (2, 2, 2, 2))
        }
        #expect(order.values == [true], "B's successful setter must not re-arm an already-armed demand")

        // Only B's first verdict ever arrives — A's own terminal entry
        // never will, exactly as Ghostty's real single-activation
        // semantics dictate.
        coordinator.noteDiagnosticsTerminalEntry(event: 2)
        #expect(
            order.values == [true, false],
            "B superseding A must have released A's stale arm, so B's own terminal entry alone can release the shared demand"
        )
    }

    /// Review round2 B2's own carve-out: a REJECTED setter call must NOT
    /// supersede the prior armed event — Ghostty's real core activation
    /// for A is left completely untouched by a rejection, so A's own
    /// terminal ring entry can still legitimately arrive later and must
    /// remain the thing demand waits for.
    @Test func rejectedSetterDoesNotSupersedeThePriorArmedEventsDemand() {
        final class Order: @unchecked Sendable {
            var values: [Bool] = []
        }
        let order = Order()
        let coordinator = ExternalHoverOwnerCoordinator(
            scheduler: { $0() },
            project: { _ in },
            manageDiagnosticsRenderDemand: { active in order.values.append(active) },
            diagnosticsEnabled: { true }
        )
        _ = coordinator.callSetterAndRecordPending(event: 1, path: "/tmp/a") {
            HoverActivationTokenValue(bits: (1, 1, 1, 1))
        }
        let rejected = coordinator.callSetterAndRecordPending(event: 2, path: "/tmp/b") { nil }
        #expect(rejected == nil)
        #expect(order.values == [true], "a rejected setter must not touch any other event's demand bookkeeping")

        coordinator.noteDiagnosticsTerminalEntry(event: 1)
        #expect(
            order.values == [true, false],
            "A's own terminal entry must still release demand — the rejection left A's real activation and arm intact"
        )
    }

    /// Review B3: the REAL Cmd-release production order — the mirror is
    /// published with `eligible == false` for the CURRENT event (exactly
    /// what the Cmd-release handler does immediately before calling
    /// `clearExternalHoverCandidate`), and withdrawal must still run: no
    /// additional mouseMoved or currentness-passing event is needed.
    /// Before the B3 fix, `withdrawCurrentCandidate`'s guard was
    /// `currentnessVerdict` itself, which rejects `eligible == false` —
    /// exactly the value this withdrawal's own trigger publishes — so the
    /// clear+drain silently never ran.
    @Test func withdrawalSucceedsWhenMirrorPublishesIneligibleForTheCurrentEventExactlyLikeCmdRelease() async {
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()
        let mintedToken = HoverActivationTokenValue(bits: (3, 3, 3, 3))
        let service = makeService(teardownCoordinator: teardownCoordinator, counts: counts, setterResult: mintedToken)

        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let request = makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )
        await service.submit(request).value
        #expect(mailboxCoordinator.currentMailbox.pending?.token == mintedToken)

        // Cmd release: publish `eligible == false` for the SAME event —
        // this IS the withdrawal's own trigger, never a rejection reason.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: false, visible: true))
        await service.withdrawCurrentCandidate(request: request, reason: "cmdRelease")

        #expect(counts.clearCalls == 1, "an eligible=false current-event withdrawal must still clear")
        #expect(counts.clearedTokens == [mintedToken])
    }

    /// Review round2 B3: the REAL Cmd-release production RACE —
    /// `ghostty_surface_mouse_pos`-triggered input-time invalidation (the
    /// native inactive-transition + `noteExternalInactive` cache-clear
    /// path) can complete BEFORE the async Cmd-release withdrawal ever
    /// runs, clearing both the mailbox's accepted owner AND the actor's
    /// own cache first. `tokenToClear == nil` is then a legitimate
    /// outcome — not proof there is nothing left to recover: a diagnostic
    /// entry can still be sitting in the ring with no other trigger left
    /// to reach it. Before the B3 fix, `withdrawCurrentCandidate`
    /// returned before ever acquiring a lease or draining once
    /// `tokenToClear` was `nil`, silently dropping that entry forever.
    @Test func withdrawalStillDrainsWhenInactiveTransitionAndCacheInvalidationRaceAheadOfIt() async {
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()
        let mintedToken = HoverActivationTokenValue(bits: (4, 4, 4, 4))
        let service = makeService(teardownCoordinator: teardownCoordinator, counts: counts, setterResult: mintedToken)

        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let request = makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 1
        )
        await service.submit(request).value
        #expect(mailboxCoordinator.currentMailbox.pending?.token == mintedToken)

        // Ghostty's real ack promotes pending -> accepted owner.
        _ = mailboxCoordinator.receiveTransition(token: mintedToken, active: true)

        // The race: input-time invalidation clears the mailbox's owner
        // AND the actor's own cache BEFORE the Cmd-release withdrawal
        // below ever runs — exactly the ordering the review describes.
        _ = mailboxCoordinator.receiveTransition(token: mintedToken, active: false)
        await service.noteExternalInactive(lifetimeID: lifetimeID, token: mintedToken).value
        #expect(mailboxCoordinator.currentMailbox.acceptedOwner == nil)

        // `submit` above already ran its own "setter 直後" drain once —
        // isolate the withdrawal's own drain by taking a delta from here.
        let drainCallsBeforeWithdrawal = counts.drainCalls

        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: false, visible: true))
        await service.withdrawCurrentCandidate(request: request, reason: "cmdRelease")

        #expect(counts.clearCalls == 0, "there is no token left to clear — callClear must not be called")
        #expect(
            counts.drainCalls == drainCallsBeforeWithdrawal + 1,
            "the withdrawal must still drain exactly once so a waiting ring entry isn't stranded"
        )
    }

    /// Review B5: `ExternalHoverWorkService` reports its dropped-count
    /// deltas into the SAME `ExternalHoverDroppedCountTracker` instance
    /// its `teardownCoordinator` dependency exposes — not merely an
    /// equal-valued copy. This is what makes the teardown coordinator's
    /// own final drain (which has no access to this actor's internals)
    /// able to linearize against exactly what this actor already
    /// reported, instead of double-reporting the ring's full cumulative
    /// count as a fresh delta.
    @Test func droppedCountTrackerIsSharedWithTheInjectedTeardownCoordinatorNotACopy() async {
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }

        let service = makeService(
            teardownCoordinator: teardownCoordinator, counts: counts,
            drainDiagnostics: { _, _ in (entries: [], droppedCountCumulative: 12) }
        )

        _ = await service.drainForRenderTrigger(
            lifetimeID: lifetimeID, surface: ExternalHoverRenderTriggerSurface(surface), surfaceSerial: 1,
            coordinator: Self.makeCoordinator()
        )

        #expect(await service.debugPreviousDroppedCount(for: lifetimeID) == 12)
        // Read straight off the teardown coordinator's OWN tracker
        // reference — proving this is the literal same instance the
        // actor wrote into, not a value that merely happens to match.
        #expect(
            teardownCoordinator.droppedCountTracker.debugPreviousDroppedCount(for: lifetimeID) == 12,
            "the teardown coordinator's own tracker must observe the actor's report directly, since they share one instance"
        )
    }

    /// Review round3 B4 (supersedes the round2 B5 version, which only
    /// looked the registry value up directly and never ran
    /// `defaultDrainExternalHoverDiagnostics`, a teardown request, or the
    /// entry decode/format/log path at all — so reverting the production
    /// formatter to `surfaceSerial: 0` would have left it green). This
    /// version runs the REAL teardown path: `enqueueRuntimeTeardown` with
    /// its DEFAULT `drainDiagnostics` resolution (never an injected
    /// closure bypassing `defaultDrainExternalHoverDiagnostics` itself —
    /// the review explicitly rejects that shortcut), which calls the
    /// injected `drainExternalHoverRing` seam for a canned entry, decodes
    /// it through the real `describeLine(surfaceSerial:)` formatter, and
    /// logs it through the real `DebugEventLog` sink. It then reads BOTH
    /// the normal path's `stage=read` line and the teardown's
    /// `stage=ghosttyValidation` line back from that sink and asserts
    /// their `surfaceSerial` values are IDENTICAL for the SAME event —
    /// the literal `(surfaceSerial, event)` join design v4 requires.
    /// Folds in review round3 B1's gate-OFF teardown-cleanup requirement
    /// too: after teardown, neither tracker may still hold this
    /// lifetime's entry, regardless of the coordinator's own gate state.
    @Test func normalPathAndTeardownDrainLogTheSameSurfaceSerialForTheSameEvent() async throws {
        let sharedEvent: UInt64 = 555
        let realSurfaceSerial: UInt64 = 424_242
        let lifetimeID = Self.makeLifetime()
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            drainExternalHoverRing: { _ in
                (
                    entries: [
                        ExternalHoverDiagEntryValue(
                            event: sharedEvent, source: 1, reason: 0, verdict: 0, flags: 0, seq: 1
                        )
                    ],
                    droppedCountCumulative: 0
                )
            },
            diagnosticsEnabled: { true }
        )
        let counts = CallCounts()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()

        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: sharedEvent, eligible: true, visible: true))
        let service = makeService(teardownCoordinator: teardownCoordinator, counts: counts)

        let sentinelBefore = "cmux-test-start-\(UUID().uuidString)"
        logDebugEvent(sentinelBefore)
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0),
            requestGeneration: sharedEvent, surfaceSerial: realSurfaceSerial
        )).value

        // The REAL teardown path — default `drainDiagnostics` resolution,
        // so it goes through `defaultDrainExternalHoverDiagnostics`
        // itself, never an injected bypass. `freeSurface` MUST be
        // overridden: the default is the real `ghostty_surface_free` on
        // our fake pointer.
        let ticket = teardownCoordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.teardownJoin",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            freeSurface: { _ in }
        )
        let completed = await ticket.wait(timeout: .seconds(5))
        #expect(completed, "the teardown ticket must complete")

        let sentinelAfter = "cmux-test-end-\(UUID().uuidString)"
        logDebugEvent(sentinelAfter)
        let contents = try await Self.waitForLogSentinel(sentinelAfter)
        guard let startRange = contents.range(of: sentinelBefore),
              let endRange = contents.range(of: sentinelAfter) else {
            Issue.record("expected both sentinels to be present in the log file")
            return
        }
        let window = contents[startRange.upperBound..<endRange.lowerBound]
        let lines = window.components(separatedBy: "\n")

        guard let normalLine = lines.first(where: {
            $0.contains("stage=read") && $0.contains("event=\(sharedEvent)") && $0.contains("outcome=accepted")
        }) else {
            Issue.record("expected the normal path's own accepted stage=read line for event=\(sharedEvent)")
            return
        }
        guard let teardownLine = lines.first(where: {
            $0.contains("stage=ghosttyValidation") && $0.contains("event=\(sharedEvent)")
        }) else {
            Issue.record(
                "expected a teardown stage=ghosttyValidation line for event=\(sharedEvent) — if this is missing, the teardown drain never reached the real formatter/log path"
            )
            return
        }
        #expect(
            normalLine.contains("surfaceSerial=\(realSurfaceSerial)"),
            "the normal path's own line must carry the real surfaceSerial"
        )
        #expect(
            teardownLine.contains("surfaceSerial=\(realSurfaceSerial)"),
            "the teardown line must carry the SAME real surfaceSerial as the normal path — the (surfaceSerial,event) join"
        )

        // Round3 B1: teardown must clean up both trackers' entries for
        // this lifetime (this particular coordinator's own gate is ON
        // throughout this test — see the dedicated gate-OFF test below
        // for the "regardless of gate state" half of the requirement).
        #expect(teardownCoordinator.surfaceSerialRegistry.serial(for: lifetimeID) == nil)
        #expect(teardownCoordinator.droppedCountTracker.debugPreviousDroppedCount(for: lifetimeID) == nil)
    }

    /// Review round3 B1: teardown cleanup must run regardless of the
    /// COORDINATOR's own diagnostics gate — a lifetime's tracker entries
    /// (populated here via the ACTOR's gate, which is a separate switch)
    /// must not survive teardown just because the coordinator's own gate
    /// happens to be off at that moment. Before the `defer`-based cleanup
    /// fix, cleanup lived AFTER the gate guard in
    /// `defaultDrainExternalHoverDiagnostics`, so a gate-OFF teardown —
    /// the common case, since `swift test` never sets the diagnostics env
    /// var and most real dogfood sessions run with it off too — never
    /// reached the cleanup lines at all, leaking every torn-down
    /// lifetime's registry/tracker entry for the life of the process.
    @Test func teardownCleansUpBothTrackersEvenWhenTheCoordinatorsOwnGateIsOff() async {
        let lifetimeID = Self.makeLifetime()
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            drainExternalHoverRing: { _ in (entries: [], droppedCountCumulative: 0) },
            diagnosticsEnabled: { false }
        )
        let counts = CallCounts()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()

        // The ACTOR's own gate is ON — a separate switch from the
        // coordinator's — so submitting a request here really does
        // populate both trackers with an entry for this lifetime.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 1, eligible: true, visible: true))
        let service = makeService(teardownCoordinator: teardownCoordinator, counts: counts)
        await service.submit(makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0),
            requestGeneration: 1, surfaceSerial: 999
        )).value
        #expect(teardownCoordinator.surfaceSerialRegistry.serial(for: lifetimeID) == 999)
        #expect(teardownCoordinator.droppedCountTracker.debugPreviousDroppedCount(for: lifetimeID) != nil)

        // Teardown, with the COORDINATOR's own gate OFF.
        let ticket = teardownCoordinator.enqueueRuntimeTeardown(
            id: lifetimeID.surfaceID,
            workspaceId: UUID(),
            reason: "test.gateOffCleanup",
            surface: surface,
            runtimeSurfaceGeneration: lifetimeID.runtimeSurfaceGeneration,
            callbackContext: nil,
            freeSurface: { _ in }
        )
        let completed = await ticket.wait(timeout: .seconds(5))
        #expect(completed, "the teardown ticket must complete")

        #expect(
            teardownCoordinator.surfaceSerialRegistry.serial(for: lifetimeID) == nil,
            "gate-OFF teardown must still discard the surfaceSerial registry entry"
        )
        #expect(
            teardownCoordinator.droppedCountTracker.debugPreviousDroppedCount(for: lifetimeID) == nil,
            "gate-OFF teardown must still discard the dropped-count tracker entry"
        )
    }

    /// Review B3: a STALE withdrawal request (mismatched lifetime/event)
    /// must still be rejected even though it's also `eligible == false` —
    /// authorizing on ineligibility must never relax the lifetime/event
    /// guard that stops a stale request from clearing a newer owner.
    @Test func withdrawalAuthorizationStillRejectsAStaleEventEvenWhenIneligible() async {
        let teardownCoordinator = TerminalSurfaceRuntimeTeardownCoordinator()
        let counts = CallCounts()
        let lifetimeID = Self.makeLifetime()
        let surface = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { surface.deallocate() }
        let mirror = HoverCallbackMirror()
        let mailboxCoordinator = Self.makeCoordinator()
        let service = makeService(teardownCoordinator: teardownCoordinator, counts: counts)

        // Mirror has moved on to event 6, ineligible — a delayed
        // withdrawal for the stale generation 5 must still be a no-op.
        mirror.publish(.init(lifetimeID: lifetimeID, hoverEventID: 6, eligible: false, visible: true))
        let staleRequest = makeRequest(
            lifetimeID: lifetimeID, mirror: mirror, coordinator: mailboxCoordinator,
            surface: surface, cell: ExternalHoverGridCell(row: 5, column: 0), requestGeneration: 5
        )
        await service.withdrawCurrentCandidate(request: staleRequest, reason: "test.stale")

        #expect(counts.clearCalls == 0)
    }
}
