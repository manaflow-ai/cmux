// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct StubSurfaceProviderTests {
    @Test func resolvesByRefAndUUID() async throws {
        let uuid = UUID()
        let info = SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: uuid,
            workspaceRef: "workspace:1",
            title: nil,
            cols: 80,
            rows: 24,
            altScreen: false,
            focused: true,
            semanticAvailable: false
        )
        let provider = StubSurfaceProvider()
        await provider.set(surfaces: [info])
        let byRef = try await provider.resolve(.ref(kind: "surface", ordinal: 1))
        let byUUID = try await provider.resolve(.uuid(uuid))
        #expect(byRef?.uuid == uuid)
        #expect(byUUID?.uuid == uuid)
    }

    @Test func cellsUnsupportedByDefault() async throws {
        let provider = StubSurfaceProvider()
        let info = SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 1),
            uuid: UUID(),
            workspaceRef: "workspace:1",
            title: nil,
            cols: 1,
            rows: 1,
            altScreen: false,
            focused: true,
            semanticAvailable: false
        )
        await provider.set(surfaces: [info])
        await #expect(throws: TerminalAccessError.self) {
            _ = try await provider.readCells(surface: info, region: .viewport)
        }
    }
}
