// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Behavioral coverage for the cells branch of
/// ``DefaultTerminalAccessService/subscribeOutput(_:onEvent:)`` (Task
/// 2.18).
///
/// The poller is wall-clock driven at `cellsTickRate=200` (5 ms), so a
/// handful of `Task.sleep` windows of 60–80 ms cover several ticks
/// without making the test slow.
@Suite struct SubscribeCellsTests {
    private static let handle = SurfaceHandle.ref(kind: "surface", ordinal: 1)

    private static func grid(letter: String) -> CellGrid {
        let cells = [
            Cell(
                t: letter, wide: .narrow, fg: .default, bg: .default,
                attrs: [], underlineKind: nil, underlineColor: nil,
                hyperlink: nil, semantic: nil
            )
        ]
        return CellGrid(
            cols: 1, rows: 1, altScreen: false, title: nil,
            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: false,
            rowsData: [CellRow(wrap: false, wrapContinuation: false, cells: cells)]
        )
    }

    actor MutableCellsProvider: SurfaceProvider {
        let canned: SurfaceInfo
        var grid: CellGrid

        init(initial: CellGrid, handle: SurfaceHandle) {
            self.grid = initial
            self.canned = SurfaceInfo(
                handle: handle, uuid: UUID(), workspaceRef: "ws:1",
                title: nil, cols: initial.cols, rows: initial.rows,
                altScreen: initial.altScreen, focused: false,
                semanticAvailable: initial.semanticAvailable
            )
        }

        func update(_ newGrid: CellGrid) { self.grid = newGrid }

        func listSurfaces() async throws -> [SurfaceInfo] { [canned] }
        func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? { canned }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid { grid }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }
    }

    actor RecordingAudit: AuditLog {
        var entries: [AuditEntry] = []
        func record(_ entry: AuditEntry) async { entries.append(entry) }
        func kinds() -> [AuditKind] { entries.map(\.kind) }
    }

    private func makeService(
        provider: MutableCellsProvider,
        audit: RecordingAudit = RecordingAudit()
    ) -> DefaultTerminalAccessService {
        DefaultTerminalAccessService(
            provider: provider,
            audit: audit,
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4),
            cellsTickRate: 200.0
        )
    }

    @Test func cellsEmitsOnlyOnContentChange() async throws {
        let provider = MutableCellsProvider(
            initial: Self.grid(letter: "a"), handle: Self.handle
        )
        let svc = makeService(provider: provider)

        let lock = NSLock()
        nonisolated(unsafe) var letters: [String] = []
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { ev in
            if case .cellsSnapshot(let g, _) = ev {
                lock.lock()
                letters.append(g.rowsData.first?.cells.first?.t ?? "")
                lock.unlock()
            }
        }

        // Wait long enough for several ticks (interval is 5 ms).
        try await Task.sleep(nanoseconds: 80_000_000)
        await provider.update(Self.grid(letter: "b"))
        try await Task.sleep(nanoseconds: 80_000_000)
        // Same content — must not emit.
        await provider.update(Self.grid(letter: "b"))
        try await Task.sleep(nanoseconds: 80_000_000)
        await provider.update(Self.grid(letter: "c"))
        try await Task.sleep(nanoseconds: 80_000_000)

        sub.cancel()
        lock.lock()
        let got = letters
        lock.unlock()
        #expect(got == ["a", "b", "c"])
    }

    @Test func cellsEmitsMonotonicSeqWithoutGaps() async throws {
        let provider = MutableCellsProvider(
            initial: Self.grid(letter: "a"), handle: Self.handle
        )
        let svc = makeService(provider: provider)

        let lock = NSLock()
        nonisolated(unsafe) var seqs: [UInt64] = []
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { ev in
            if case .cellsSnapshot(_, let s) = ev {
                lock.lock(); seqs.append(s); lock.unlock()
            }
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        await provider.update(Self.grid(letter: "b"))
        try await Task.sleep(nanoseconds: 80_000_000)
        await provider.update(Self.grid(letter: "c"))
        try await Task.sleep(nanoseconds: 80_000_000)
        sub.cancel()

        lock.lock(); let got = seqs; lock.unlock()
        #expect(got.count >= 2)
        // EventRing assigns strictly monotonic seq values starting at 1.
        #expect(got == Array(1...UInt64(got.count)))
    }

    @Test func cellsAuditRecordsOpenAndClose() async throws {
        let provider = MutableCellsProvider(
            initial: Self.grid(letter: "a"), handle: Self.handle
        )
        let audit = RecordingAudit()
        let svc = makeService(provider: provider, audit: audit)

        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { _ in }
        try await Task.sleep(nanoseconds: 30_000_000)
        sub.cancel()
        try await Task.sleep(nanoseconds: 80_000_000)

        let kinds = await audit.kinds()
        #expect(kinds.contains(.streamOpen))
        #expect(kinds.contains(.streamClose))
    }

    @Test func cancelStopsPollerEmissions() async throws {
        let provider = MutableCellsProvider(
            initial: Self.grid(letter: "a"), handle: Self.handle
        )
        let svc = makeService(provider: provider)

        let lock = NSLock()
        nonisolated(unsafe) var emissions = 0
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { ev in
            if case .cellsSnapshot = ev {
                lock.lock(); emissions += 1; lock.unlock()
            }
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        sub.cancel()
        lock.lock(); let snapshot = emissions; lock.unlock()
        // After cancel(), changing the grid must not produce more
        // emissions on the cancelled subscriber's callback.
        await provider.update(Self.grid(letter: "z"))
        try await Task.sleep(nanoseconds: 100_000_000)
        lock.lock(); let after = emissions; lock.unlock()
        #expect(snapshot == after)
    }
}
