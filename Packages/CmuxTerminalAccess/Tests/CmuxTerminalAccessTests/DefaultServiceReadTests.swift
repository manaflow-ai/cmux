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

    @Test func cellsRejectedAsUnsupported415InPhase0() async throws {
        let (svc, info, _) = await makeService(text: "")
        await #expect(throws: TerminalAccessError.self) {
            _ = try await svc.readScreen(.init(handle: info.handle, format: .cells))
        }
    }

    @Test func wrapJoinRejectedAsUnsupported415InPhase0() async throws {
        let (svc, info, _) = await makeService(text: "")
        await #expect(throws: TerminalAccessError.self) {
            _ = try await svc.readScreen(.init(handle: info.handle, wrap: .join))
        }
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
