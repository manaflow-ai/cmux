// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Verify that ``OutputSubscription/signalEnd()`` fires
/// `onEnd` when the underlying surface closes, and that
/// ``SurfaceProvider/observeClose(_:onClose:)`` is the seam that
/// triggers it (Task 2.19, D22).
///
/// Raw-mode end-of-stream coverage lands with ghostty patch #2 (Task
/// 2.17); this suite exercises the cells branch which is fully wired
/// in this batch.
@Suite struct StreamEndOnSurfaceCloseTests {
    private static let handle = SurfaceHandle.ref(kind: "surface", ordinal: 1)

    private static func grid() -> CellGrid {
        let cells = [
            Cell(
                t: "x", wide: .narrow, fg: .default, bg: .default,
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

    /// Provider whose ``observeClose`` records the closer so the test
    /// can fire it on demand. All other methods are no-ops.
    final class ClosableProvider: SurfaceProvider, @unchecked Sendable {
        let canned: SurfaceInfo
        private let lock = NSLock()
        private var closer: (@Sendable () -> Void)?

        init(handle: SurfaceHandle) {
            self.canned = SurfaceInfo(
                handle: handle, uuid: UUID(), workspaceRef: "ws:1",
                title: nil, cols: 1, rows: 1, altScreen: false,
                focused: false, semanticAvailable: false
            )
        }

        func listSurfaces() async throws -> [SurfaceInfo] { [canned] }
        func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? { canned }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String { "" }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
            StreamEndOnSurfaceCloseTests.grid()
        }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 1 << 20 }

        func observeClose(
            _ handle: SurfaceHandle,
            onClose: @escaping @Sendable () -> Void
        ) async throws -> AnyObject {
            lock.lock(); closer = onClose; lock.unlock()
            return NSObject()
        }

        func fireClose() {
            lock.lock(); let c = closer; lock.unlock()
            c?()
        }
    }

    @Test func subscriberSeesOnEndWhenSurfaceCloses() async throws {
        let provider = ClosableProvider(handle: Self.handle)
        let svc = DefaultTerminalAccessService(
            provider: provider,
            audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4)
        )

        let lock = NSLock()
        nonisolated(unsafe) var sawEnd = false
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { _ in }
        sub.onEnd = { lock.lock(); sawEnd = true; lock.unlock() }

        provider.fireClose()
        try await Task.sleep(nanoseconds: 80_000_000)
        lock.lock(); let got = sawEnd; lock.unlock()
        #expect(got)
    }

    @Test func signalEndIsIdempotent() async throws {
        let provider = ClosableProvider(handle: Self.handle)
        let svc = DefaultTerminalAccessService(
            provider: provider,
            audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4)
        )

        let lock = NSLock()
        nonisolated(unsafe) var endCount = 0
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { _ in }
        sub.onEnd = { lock.lock(); endCount += 1; lock.unlock() }

        provider.fireClose()
        provider.fireClose()
        provider.fireClose()
        try await Task.sleep(nanoseconds: 60_000_000)
        lock.lock(); let got = endCount; lock.unlock()
        #expect(got == 1)
    }

    @Test func subscriptionEventsStreamFinishesOnSignalEnd() async throws {
        let provider = ClosableProvider(handle: Self.handle)
        let svc = DefaultTerminalAccessService(
            provider: provider,
            audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: StreamCap(maxPerSurface: 4)
        )

        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: Self.handle, mode: .cells)
        ) { _ in }
        let stream = sub.events()
        let collector = Task<Bool, Never> {
            for await _ in stream { /* drain */ }
            return true
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        provider.fireClose()
        let finished = await collector.value
        #expect(finished)
    }
}
