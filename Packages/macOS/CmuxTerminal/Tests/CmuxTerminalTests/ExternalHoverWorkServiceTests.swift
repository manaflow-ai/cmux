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
        onProject: @escaping (ExternalHoverMailbox.Entry?) -> Void = { _ in }
    ) -> ExternalHoverOwnerCoordinator {
        ExternalHoverOwnerCoordinator(scheduler: { $0() }, project: onProject)
    }

    private final class CallCounts: @unchecked Sendable {
        var reads = 0
        var setterCalls = 0
        var clearCalls = 0
        var clearedTokens: [HoverActivationTokenValue] = []
    }

    private func makeRequest(
        lifetimeID: RuntimeSurfaceLifetimeID,
        mirror: HoverCallbackMirror,
        coordinator: ExternalHoverOwnerCoordinator,
        surface: ghostty_surface_t,
        cell: ExternalHoverGridCell,
        requestGeneration: UInt64
    ) -> ExternalHoverWorkRequest {
        .init(
            lifetimeID: lifetimeID,
            surface: surface,
            requestGeneration: requestGeneration,
            cell: cell,
            viewportRowCount: 10,
            cwd: "/tmp",
            mirror: mirror,
            coordinator: coordinator
        )
    }

    private func makeService(
        teardownCoordinator: TerminalSurfaceRuntimeTeardownCoordinator,
        counts: CallCounts,
        onRead: (@Sendable () -> Void)? = nil,
        setterResult: HoverActivationTokenValue? = HoverActivationTokenValue(bits: (1, 1, 1, 1))
    ) -> ExternalHoverWorkService {
        ExternalHoverWorkService(
            teardownCoordinator: teardownCoordinator,
            resolver: TerminalPathResolver(fileExists: { $0 == Self.existingPath }),
            readPhysicalRows: { _, _, _ in
                counts.reads += 1
                onRead?()
                return Self.physicalRowsText
            },
            callSetter: { _, _, _, _, _ in
                counts.setterCalls += 1
                return setterResult
            },
            callClear: { _, token in
                counts.clearCalls += 1
                counts.clearedTokens.append(token)
            }
        )
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
            callSetter: { _, _, _, _, _ in
                counts.setterCalls += 1
                return HoverActivationTokenValue(bits: (1, 1, 1, 1))
            },
            callClear: { _, token in
                counts.clearCalls += 1
                counts.clearedTokens.append(token)
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
}
