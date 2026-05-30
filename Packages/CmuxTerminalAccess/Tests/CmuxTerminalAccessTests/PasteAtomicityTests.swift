// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct PasteAtomicityTests {
    /// Stub that simulates slow per-write fanout: each `writeText`
    /// call records its bytes after a short async yield, so without
    /// per-surface serialization the recorded byte sequence would
    /// interleave the two payloads.
    ///
    /// Per Errata E1, this stub matches the locked
    /// ``SurfaceProvider`` shape: no `attachRawOutput` required
    /// member and ``pendingInputCapacityRemaining(surface:)`` is
    /// synchronous.
    actor SlowWrite: SurfaceProvider {
        let info: SurfaceInfo
        var recorded: [Data] = []
        init() {
            info = SurfaceInfo(
                handle: .ref(kind: "surface", ordinal: 1),
                uuid: UUID(),
                workspaceRef: "workspace:1",
                title: nil,
                cols: 80,
                rows: 24,
                altScreen: false,
                focused: true,
                semanticAvailable: false
            )
        }
        func listSurfaces() async throws -> [SurfaceInfo] { [info] }
        func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? {
            (h == info.handle || h == .uuid(info.uuid)) ? info : nil
        }
        func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String {
            ""
        }
        func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
            throw TerminalAccessError.unsupported(reason: "n/a")
        }
        func writeText(surface: SurfaceInfo, bytes: Data) async throws {
            // Yield twice so the scheduler has plenty of chances to
            // interleave a non-serialized concurrent caller.
            await Task.yield()
            await Task.yield()
            recorded.append(bytes)
        }
        func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
        func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
        func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
        nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int {
            1 << 20
        }
    }

    @Test func concurrentPastesDoNotInterleave() async throws {
        let provider = SlowWrite()
        let svc = DefaultTerminalAccessService(
            provider: provider,
            audit: NoOpAuditLog()
        )
        let info = await provider.info
        let a = String(repeating: "A", count: 64)
        let b = String(repeating: "B", count: 64)

        async let p1: Void = svc.writeInput(
            .init(handle: info.handle, payload: .paste(a))
        )
        async let p2: Void = svc.writeInput(
            .init(handle: info.handle, payload: .paste(b))
        )
        _ = try await [p1, p2]

        let recorded = await provider.recorded
        #expect(recorded.count == 2)
        #expect(Set(recorded) == Set([Data(a.utf8), Data(b.utf8)]))
        // Each recorded blob is a single contiguous payload —
        // neither contains the other byte's character.
        for blob in recorded {
            let only = Set(blob)
            #expect(only.count == 1)
        }
    }
}
