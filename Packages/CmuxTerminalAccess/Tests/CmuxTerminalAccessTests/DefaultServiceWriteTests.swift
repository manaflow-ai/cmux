// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct DefaultServiceWriteTests {
    /// Errata E2 — `AuditLog.record` is `async` non-throwing. The
    /// test recorder is an `actor` so appends are serialized without
    /// a lock.
    actor RecordingAudit: AuditLog {
        var entries: [AuditEntry] = []
        func record(_ entry: AuditEntry) async {
            entries.append(entry)
        }
    }

    private func setUp() async -> (
        DefaultTerminalAccessService,
        SurfaceInfo,
        StubSurfaceProvider,
        RecordingAudit
    ) {
        let info = SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(),
            workspaceRef: "workspace:1",
            title: nil,
            cols: 80,
            rows: 24,
            altScreen: false,
            focused: false,
            semanticAvailable: false
        )
        let stub = StubSurfaceProvider()
        await stub.set(surfaces: [info])
        let audit = RecordingAudit()
        // E3 — DefaultTerminalAccessService.init has defaults for
        // rateLimiter / streamCap / cellsTickRate; allowRawInput
        // defaults to { false }.
        let svc = DefaultTerminalAccessService(provider: stub, audit: audit)
        return (svc, info, stub, audit)
    }

    @Test func textWithSubmitAppendsCR() async throws {
        let (svc, info, stub, audit) = await setUp()
        try await svc.writeInput(
            .init(handle: info.handle, payload: .text("ls", submit: true))
        )
        let writes = await stub.textWrites
        // E1 — submit=true dispatches writeText("ls") + writeKey(.enter);
        // the text payload itself carries no embedded CR.
        #expect(writes == [Data([0x6c, 0x73])])
        let keys = await stub.keyWrites
        #expect(keys.count == 1)
        let entries = await audit.entries
        #expect(entries.first?.kind == .writeText)
    }

    @Test func keysFanOutToProvider() async throws {
        let (svc, info, stub, _) = await setUp()
        try await svc.writeInput(
            .init(
                handle: info.handle,
                payload: .keys([
                    try KeyEvent.parse("Ctrl+C"),
                    try KeyEvent.parse("Up"),
                ])
            )
        )
        let keys = await stub.keyWrites
        #expect(keys.count == 2)
    }

    @Test func rawRejectedByDefault() async throws {
        let (svc, info, _, _) = await setUp()
        await #expect(throws: TerminalAccessError.self) {
            try await svc.writeInput(
                .init(handle: info.handle, payload: .raw(Data([0x1B])))
            )
        }
    }

    @Test func rawAllowedWhenGateOpen() async throws {
        // E3 — allowRawInput is an init-time closure; set it via the
        // constructor.
        let info = SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(),
            workspaceRef: "workspace:1",
            title: nil,
            cols: 80,
            rows: 24,
            altScreen: false,
            focused: false,
            semanticAvailable: false
        )
        let stub = StubSurfaceProvider()
        await stub.set(surfaces: [info])
        let audit = RecordingAudit()
        let svc = DefaultTerminalAccessService(
            provider: stub,
            audit: audit,
            allowRawInput: { true }
        )
        try await svc.writeInput(
            .init(handle: info.handle, payload: .raw(Data([0x1B])))
        )
        let writes = await stub.textWrites
        #expect(writes == [Data([0x1B])])
        let entries = await audit.entries
        #expect(entries.contains { $0.kind == .writeRaw })
    }

    @Test func payloadTooLargeWhenCapacityExceeded() async throws {
        // Uses a dedicated capacity-aware spy provider — the shared
        // StubSurfaceProvider per E1 returns a large constant for
        // capacity remaining; this provider returns a small constant.
        // The capacity precondition runs inside enforceCapacity
        // (E14) before any provider write.
        actor TinyCapacityProvider: SurfaceProvider {
            let info: SurfaceInfo
            init(_ info: SurfaceInfo) { self.info = info }
            func listSurfaces() async throws -> [SurfaceInfo] { [info] }
            func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? {
                (h == info.handle || h == .uuid(info.uuid)) ? info : nil
            }
            func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String {
                ""
            }
            func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
                throw TerminalAccessError.unsupported(reason: "stub")
            }
            func writeText(surface: SurfaceInfo, bytes: Data) async throws {}
            func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {}
            func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {}
            func setFocus(surface: SurfaceInfo, gained: Bool) async throws {}
            nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int { 4 }
        }
        let info = SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(),
            workspaceRef: "workspace:1",
            title: nil,
            cols: 80,
            rows: 24,
            altScreen: false,
            focused: false,
            semanticAvailable: false
        )
        let svc = DefaultTerminalAccessService(
            provider: TinyCapacityProvider(info),
            audit: NoOpAuditLog()
        )
        await #expect(throws: TerminalAccessError.payloadTooLarge) {
            try await svc.writeInput(
                .init(
                    handle: info.handle,
                    payload: .text(String(repeating: "x", count: 5), submit: false)
                )
            )
        }
    }

    @Test func mouseGoesDirectlyToProviderNeverNSEvent() async throws {  // D16
        let (svc, info, stub, _) = await setUp()
        let m = MouseEvent(action: .press, button: .left, x: 5, y: 7, mods: [], scrollDy: 0)
        try await svc.writeInput(
            .init(handle: info.handle, payload: .mouse(m))
        )
        let mw = await stub.mouseWrites
        let nse = await stub.nsEventBuilds
        #expect(mw == [m])
        #expect(nse == 0)
    }

    @Test func focusSurfaceCallsSetFocusBeforeWrite() async throws {  // D17
        let (svc, info, stub, _) = await setUp()
        try await svc.writeInput(
            .init(
                handle: info.handle,
                payload: .text("x", submit: false),
                focusSurface: true
            )
        )
        let foci = await stub.focusWrites
        let writes = await stub.textWrites
        #expect(foci == [true])
        #expect(writes == [Data([0x78])])
    }

    @Test func focusOnlyPayloadCallsSetFocusOnce() async throws {
        let (svc, info, stub, audit) = await setUp()
        try await svc.writeInput(
            .init(handle: info.handle, payload: .focus(gained: false))
        )
        let foci = await stub.focusWrites
        #expect(foci == [false])
        let entries = await audit.entries
        #expect(entries.last?.kind == .writeFocus)
    }
}
