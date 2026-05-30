// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Skeleton coverage for ``DefaultTerminalAccessService/subscribeOutput(_:onEvent:)``
/// (Task 2.16).
///
/// Raw mode is gated behind ghostty patch #2 (Task 2.15) so it throws
/// ``TerminalAccessError/unsupported(reason:)`` (HTTP 415, D18). Cells
/// mode returns a real ``OutputSubscription`` whose `handle`/`mode`
/// match ``StreamSubscriptionOptions`` (D22). The per-surface
/// ``StreamCap`` slot is released both on the raw-mode failure path and
/// on `OutputSubscription.cancel()`.
@Suite struct SubscribeOutputSkeletonTests {
    private func handle(_ ord: Int = 1) -> SurfaceHandle {
        .ref(kind: "surface", ordinal: ord)
    }

    private func makeService(
        cap: StreamCap = StreamCap(maxPerSurface: 8),
        cannedCells: CellGrid? = nil
    ) async -> (DefaultTerminalAccessService, StubSurfaceProvider) {
        let provider = StubSurfaceProvider()
        let info = SurfaceInfo(
            handle: handle(), uuid: UUID(), workspaceRef: "ws:1",
            title: nil, cols: 80, rows: 24, altScreen: false,
            focused: false, semanticAvailable: false
        )
        await provider.set(surfaces: [info])
        if let g = cannedCells { await provider.set(cannedCells: g) }
        let svc = DefaultTerminalAccessService(
            provider: provider,
            audit: NoOpAuditLog(),
            rateLimiter: RateLimiter(burstCapacity: 1000, refillPerSecond: 1000),
            streamCap: cap
        )
        return (svc, provider)
    }

    @Test func rawModeThrowsUnsupportedUntilGhosttyPatch2() async {
        let cap = StreamCap(maxPerSurface: 4)
        let (svc, _) = await makeService(cap: cap)
        do {
            _ = try await svc.subscribeOutput(
                StreamSubscriptionOptions(handle: handle(), mode: .raw)
            ) { _ in }
            Issue.record("expected raw subscribe to throw .unsupported")
        } catch let TerminalAccessError.unsupported(reason) {
            #expect(reason.contains("ghostty patch #2"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        // D24 / E14 — failure path releases the cap token so subsequent
        // subscribes do not see a leaked slot.
        #expect(cap.openCount(for: handle()) == 0)
    }

    @Test func cellsModeReturnsSubscriptionWithMatchingHandleAndMode() async throws {
        let (svc, _) = await makeService()
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: handle(), mode: .cells)
        ) { _ in }
        #expect(sub.handle == handle())
        #expect(sub.mode == .cells)
        sub.cancel()
    }

    @Test func cancelReleasesCapSlot() async throws {
        let cap = StreamCap(maxPerSurface: 4)
        let (svc, _) = await makeService(cap: cap)
        let sub = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: handle(), mode: .cells)
        ) { _ in }
        #expect(cap.openCount(for: handle()) == 1)
        sub.cancel()
        #expect(cap.openCount(for: handle()) == 0)
        // D24 — second cancel is idempotent and must not double-release.
        sub.cancel()
        #expect(cap.openCount(for: handle()) == 0)
    }

    @Test func unknownSurfaceReleasesCapTokenAndThrows() async {
        let cap = StreamCap(maxPerSurface: 4)
        let (svc, _) = await makeService(cap: cap)
        do {
            _ = try await svc.subscribeOutput(
                StreamSubscriptionOptions(
                    handle: .ref(kind: "surface", ordinal: 999),
                    mode: .cells
                )
            ) { _ in }
            Issue.record("expected unknownSurface to throw")
        } catch let err as TerminalAccessError {
            #expect(err == .unknownSurface)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(cap.openCount(for: .ref(kind: "surface", ordinal: 999)) == 0)
    }

    @Test func perSurfaceCapExhaustionThrowsTooManyStreams() async throws {
        let cap = StreamCap(maxPerSurface: 1)
        let (svc, _) = await makeService(cap: cap)
        let first = try await svc.subscribeOutput(
            StreamSubscriptionOptions(handle: handle(), mode: .cells)
        ) { _ in }
        do {
            _ = try await svc.subscribeOutput(
                StreamSubscriptionOptions(handle: handle(), mode: .cells)
            ) { _ in }
            Issue.record("expected second subscribe to be capped")
        } catch let TerminalAccessError.unsupported(reason) {
            // D7 + Task 2.23 — HTTP layer matches this exact reason
            // string and maps to 503; package-level callers receive
            // .unsupported with the reason intact.
            #expect(reason == "too_many_streams")
        } catch {
            Issue.record("unexpected error \(error)")
        }
        first.cancel()
    }
}
