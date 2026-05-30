// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct DefaultServiceReadTests {
    private func makeService(
        text: String
    ) async -> (DefaultTerminalAccessService, SurfaceInfo, StubSurfaceProvider) {
        let info = SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(),
            workspaceRef: "workspace:1",
            title: "t",
            cols: 80,
            rows: 24,
            altScreen: false,
            focused: true,
            semanticAvailable: false
        )
        let stub = StubSurfaceProvider()
        await stub.set(surfaces: [info])
        await stub.set(cannedText: text)
        let svc = DefaultTerminalAccessService(provider: stub, audit: NoOpAuditLog())
        return (svc, info, stub)
    }

    @Test func unknownSurfaceMaps() async throws {
        let (svc, _, _) = await makeService(text: "")
        await #expect(throws: TerminalAccessError.unknownSurface) {
            _ = try await svc.readScreen(
                .init(handle: .ref(kind: "surface", ordinal: 99))
            )
        }
    }

    @Test func textReadReturnsTextPayload() async throws {
        let (svc, info, _) = await makeService(text: "hello\n")
        let res = try await svc.readScreen(.init(handle: info.handle, trim: false))
        guard case .text(let p) = res else {
            Issue.record("not text")
            return
        }
        #expect(p.text == "hello\n")
        #expect(p.cols == 80)
    }

    @Test func cellsThrowsUnsupportedWhenProviderLacksGhosttyPatch() async throws {
        // Per E20, ``readCells`` is required on ``SurfaceProvider``;
        // conformers without ghostty patch #1 throw `.unsupported`.
        // The stub provider returns `.unsupported` when no canned grid
        // is configured. The service propagates that error so the HTTP
        // route layer can map it to 415 (D18). Once Task 1.5-1.9 land
        // patch #1, the AppSurfaceProvider readCells returns a real
        // grid; this test still covers the propagation invariant.
        let (svc, info, _) = await makeService(text: "")
        await #expect(throws: TerminalAccessError.self) {
            _ = try await svc.readScreen(.init(handle: info.handle, format: .cells))
        }
    }

    @Test func wrapJoinAcceptedInPhase1() async throws {
        // Phase 1 accepts `wrap=join` (the plan calls it open in v1).
        // Pre-patch-#1 the stub provider's text payload is returned
        // unchanged; join semantics light up once `readCells` is real.
        let (svc, info, _) = await makeService(text: "hello")
        let res = try await svc.readScreen(.init(handle: info.handle, wrap: .join))
        guard case .text(let p) = res else {
            Issue.record("not text")
            return
        }
        #expect(p.text == "hello")
    }

    @Test func trimRemovesTrailingSpaces() async throws {
        let (svc, info, _) = await makeService(text: "hi   \nthere   \n")
        let res = try await svc.readScreen(.init(handle: info.handle, trim: true))
        guard case .text(let p) = res else {
            Issue.record("not text")
            return
        }
        #expect(p.text == "hi\nthere\n")
    }
}
