// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct PasteSerializerTests {
    @Test func runsBodiesSeriallyPerSurface() async throws {
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
        let serializer = PasteSerializer()
        actor Order {
            var seq: [Int] = []
            func append(_ n: Int) { seq.append(n) }
        }
        let order = Order()
        async let a: Void = serializer.run(surface: info) {
            try await Task.sleep(nanoseconds: 5_000_000)
            await order.append(1)
        }
        async let b: Void = serializer.run(surface: info) {
            await order.append(2)
        }
        _ = try await (a, b)
        #expect(await order.seq == [1, 2])
    }

    @Test func crossSurfaceCallsRunConcurrently() async throws {
        let infoA = SurfaceInfo(
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
        let infoB = SurfaceInfo(
            handle: .ref(kind: "surface", ordinal: 2),
            uuid: UUID(),
            workspaceRef: "workspace:1",
            title: nil,
            cols: 1,
            rows: 1,
            altScreen: false,
            focused: true,
            semanticAvailable: false
        )
        let serializer = PasteSerializer()
        actor Order {
            var seq: [Int] = []
            func append(_ n: Int) { seq.append(n) }
        }
        let order = Order()
        // A sleeps long; B should not wait for A because they target
        // different surfaces.
        async let a: Void = serializer.run(surface: infoA) {
            try await Task.sleep(nanoseconds: 20_000_000)
            await order.append(1)
        }
        async let b: Void = serializer.run(surface: infoB) {
            await order.append(2)
        }
        _ = try await (a, b)
        #expect(await order.seq == [2, 1])
    }
}
