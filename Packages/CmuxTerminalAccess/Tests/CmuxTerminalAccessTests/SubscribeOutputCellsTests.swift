// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// End-to-end happy-path coverage for
/// ``DefaultTerminalAccessService/subscribeOutput(_:onEvent:)`` with
/// ``StreamMode/cells``.
///
/// Complements ``SubscribeCellsTests`` (which inspects the onEvent
/// callback path) and ``StreamEndOnSurfaceCloseTests`` (which inspects
/// the onEnd hook). This suite welds both together against the actual
/// wiring contract:
///
/// - The cells branch of ``DefaultTerminalAccessService`` delivers
///   ``OutputEvent/cellsSnapshot(_:seq:)`` instances to the caller's
///   `onEvent` closure as the ``SnapshotPoller`` ticks. The
///   ``OutputSubscription/events()`` AsyncStream is a separate seam
///   the SSE responder fills by re-yielding from `onEvent` (see
///   ``HTTPControl/StreamRoute``).
/// - Closing the surface fires ``OutputSubscription/onEnd`` and
///   finishes the ``OutputSubscription/events()`` stream cleanly,
///   so the SSE writer can emit a terminal `event: end` frame.
@Suite struct SubscribeOutputCellsTests {
    private static let handle = SurfaceHandle.ref(kind: "surface", ordinal: 42)

    private static func grid(letter: String) -> CellGrid {
        let cell = Cell(
            t: letter, wide: .narrow, fg: .default, bg: .default,
            attrs: [], underlineKind: nil, underlineColor: nil,
            hyperlink: nil, semantic: nil
        )
        return CellGrid(
            cols: 1, rows: 1, altScreen: false, title: nil,
            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: false,
            rowsData: [CellRow(wrap: false, wrapContinuation: false, cells: [cell])]
        )
    }

    /// Provider that exposes both a mutable cell grid (for SnapshotPoller
    /// dirty detection) and a close-observer fire hook (for end-of-
    /// stream tests). All reads/writes go through the actor.
    actor MutableClosableProvider: SurfaceProvider {
        let canned: SurfaceInfo
        private(set) var grid: CellGrid
        private(set) var closer: (@Sendable () -> Void)?

        init(initial: CellGrid, handle: SurfaceHandle) {
            self.grid = initial
            self.canned = SurfaceInfo(
                handle: handle, uuid: UUID(), workspaceRef: "ws:1",
                title: nil, cols: initial.cols, rows: initial.rows,
                altScreen: initial.altScreen, focused: false,
                semanticAvailable: initial.semanticAvailable
            )
        }
        func update(_ g: CellGrid) { grid = g }
        func fireClose() { closer?() }

        func listSurfaces() async throws -> [SurfaceInfo] { [canned] }
        func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? { canned }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid { grid }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }
        func observeClose(
            _ handle: SurfaceHandle,
            onClose: @escaping @Sendable () -> Void
        ) async throws -> AnyObject {
            closer = onClose
            return NSObject()
        }
    }

    private func makeService(
        provider: MutableClosableProvider
    ) -> DefaultTerminalAccessService {
        DefaultTerminalAccessService(
            provider: provider,
            audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4),
            cellsTickRate: 200.0  // 5 ms interval
        )
    }

    /// subscribeOutput(.cells) returns an ``OutputSubscription`` whose
    /// `onEvent` callback receives at least one cells snapshot once the
    /// SnapshotPoller has ticked, and the snapshot's payload matches
    /// the surface's current grid.
    @Test func cellsSnapshotReachesOnEventAfterPollerTick() async throws {
        let provider = MutableClosableProvider(
            initial: Self.grid(letter: "a"), handle: Self.handle
        )
        let svc = makeService(provider: provider)

        let lock = NSLock()
        nonisolated(unsafe) var letters: [String] = []
        nonisolated(unsafe) var seqs: [UInt64] = []
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { ev in
            if case .cellsSnapshot(let g, let s) = ev {
                lock.lock()
                letters.append(g.rowsData.first?.cells.first?.t ?? "")
                seqs.append(s)
                lock.unlock()
            }
        }
        #expect(sub.handle == Self.handle)
        #expect(sub.mode == .cells)

        // Wait long enough for several ticks (interval is 5 ms).
        try await Task.sleep(nanoseconds: 80_000_000)
        await provider.update(Self.grid(letter: "b"))
        try await Task.sleep(nanoseconds: 80_000_000)
        sub.cancel()

        lock.lock()
        let got = letters
        let gotSeqs = seqs
        lock.unlock()
        #expect(got.count >= 1, "onEvent must receive at least one snapshot")
        #expect(got.first == "a", "first snapshot reflects the initial grid")
        #expect(got.contains("b"), "post-change snapshot is delivered too")
        // Seq values from the per-subscriber EventRing are strictly
        // monotonic starting at 1 (no overflow expected at this volume).
        #expect(gotSeqs == Array(1...UInt64(gotSeqs.count)))
    }

    /// Closing the surface drives end-of-stream via ``observeClose``:
    /// the events() AsyncStream finishes, ``OutputSubscription/onEnd``
    /// fires exactly once, and a redundant close fire is a no-op.
    @Test func surfaceCloseEndsStreamAndFiresOnEndOnce() async throws {
        let provider = MutableClosableProvider(
            initial: Self.grid(letter: "a"), handle: Self.handle
        )
        let svc = makeService(provider: provider)
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { _ in }

        let lock = NSLock()
        nonisolated(unsafe) var endHits = 0
        sub.onEnd = { lock.lock(); endHits += 1; lock.unlock() }

        let stream = sub.events()
        let collector = Task<Bool, Never> {
            for await _ in stream { /* drain */ }
            return true
        }
        // Give the poller time to start ticking, then fire surface close.
        try await Task.sleep(nanoseconds: 40_000_000)
        await provider.fireClose()
        // Redundant fires must remain a no-op (signalEnd is idempotent).
        await provider.fireClose()
        await provider.fireClose()

        let finished = await collector.value
        #expect(finished, "events() must finish cleanly after surface close")
        lock.lock(); let hits = endHits; lock.unlock()
        #expect(hits == 1, "onEnd must fire exactly once across N close fires")
    }
}
