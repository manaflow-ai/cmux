// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct DefaultServiceAuditAlwaysOnTests {
    // E2 — `AuditLog.record` is `async` non-throwing.
    actor RecordingAudit: AuditLog {
        var entries: [AuditEntry] = []
        func record(_ e: AuditEntry) async { entries.append(e) }
        func snapshot() -> [AuditEntry] { entries }
    }

    @Test func writesAreAuditedRegardlessOfSettings() async throws {
        let provider = StubSurfaceProvider()
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
        await provider.set(surfaces: [info])
        let audit = RecordingAudit()
        let service = DefaultTerminalAccessService(
            provider: provider,
            audit: audit,
            rateLimiter: RateLimiter(
                burstCapacity: 1_000,
                refillPerSecond: 1_000
            )
        )
        let req = InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .text("ls", submit: false),
            focusSurface: false
        )
        try await service.writeInput(req)
        let recorded = await audit.snapshot()
        #expect(recorded.count == 1)
        #expect(recorded[0].kind == .writeText)
        #expect(recorded[0].byteCount == 2)
    }

    @Test func rateLimitExceededThrows() async throws {
        let provider = StubSurfaceProvider()
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
        await provider.set(surfaces: [info])
        let audit = RecordingAudit()
        // burstCapacity = 1, refill near-zero — second acquire throws.
        let service = DefaultTerminalAccessService(
            provider: provider,
            audit: audit,
            rateLimiter: RateLimiter(
                burstCapacity: 1,
                refillPerSecond: 0.0001
            )
        )
        let req = InputRequest(
            handle: .ref(kind: "surface", ordinal: 1),
            payload: .text("a", submit: false),
            focusSurface: false
        )
        try await service.writeInput(req)
        await #expect(throws: TerminalAccessError.self) {
            try await service.writeInput(req)
        }
    }
}
