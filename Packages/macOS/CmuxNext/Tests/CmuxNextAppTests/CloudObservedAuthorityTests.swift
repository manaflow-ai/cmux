import Foundation
import Testing
@testable import CmuxNextCloud

@MainActor
@Suite struct CloudObservedAuthorityTests {
    @Test(arguments: ["recheck", "install", "session", "call", "wire", "native", "refresh", "reselect"])
    func lossRevokesEveryPreviouslyIssuedCapability(operation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudObservedAuthorityTestWorld(root: root)
        let raw = try await world.snapshot()
        try world.observed.bind(raw, identity: world.identity)
        let capability = try world.observed.snapshot()
        world.observed.clear()
        #expect(throws: CloudTeamScope.Failure.unavailable) { try world.observed.snapshot() }
        await #expect(throws: (any Error).self) {
            switch operation {
            case "recheck": try await capability.recheck()
            case "install": _ = try await capability.installToken()
            case "session": _ = try await capability.sessionToken()
            case "call": _ = try await capability.call("/v1/ops", Data(#"{"op":"feed.answer","params":{}}"#.utf8))
            case "wire": _ = try await capability.wireLeases()
            case "native": _ = try await capability.nativeContext()
            case "refresh": _ = try await capability.refreshAuthority()
            default: _ = try await capability.reselectAuthority()
            }
        }
        #expect(await world.owner.operationTeams.isEmpty)
    }

    @Test func reconnectKeepsIdempotencyIdentityButCannotReviveAnOldCapability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudObservedAuthorityTestWorld(root: root)
        let raw = try await world.snapshot()
        try world.observed.bind(raw, identity: world.identity)
        let old = try world.observed.snapshot()
        world.observed.clear()
        try world.observed.bind(raw, identity: world.identity)
        let replacement = try world.observed.snapshot()
        #expect(old.id == replacement.id && replacement.id == raw.id)
        await #expect(throws: (any Error).self) { try await old.recheck() }
        try await replacement.recheck()
        world.identity = .init(generation: 2, accountID: "stack_1")
        await #expect(throws: (any Error).self) { try await replacement.installToken() }
        #expect(throws: (any Error).self) { try world.observed.snapshot() }
    }

    @Test func aHeldResponseCannotEscapeAfterLossEvenIfTheSameScopeWasRepublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudObservedAuthorityTestWorld(root: root), gate = CloudObservedAuthorityTestGate()
        let raw = try await world.snapshot()
        try world.observed.bind(raw, identity: world.identity)
        let capability = try world.observed.snapshot()
        await world.owner.onOperationReply { await gate.hold() }
        let call = Task { try await capability.call("/v1/ops", Data(#"{"op":"feed.answer","params":{}}"#.utf8)) }
        await gate.waitUntilHeld()
        world.observed.clear()
        try world.observed.bind(raw, identity: world.identity)
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await call.value }
        #expect(await world.owner.operationTeams == [raw.team])
    }

    @Test func operationAuthorityCannotPublishAnUnobservedRefreshResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let world = CloudObservedAuthorityTestWorld(root: root)
        let raw = try await world.snapshot()
        try world.observed.bind(raw, identity: world.identity)
        let capability = try world.observed.snapshot()
        await #expect(throws: (any Error).self) { try await capability.refreshAuthority() }
        await #expect(throws: (any Error).self) { try await capability.reselectAuthority() }
        try await raw.recheck()
        #expect(await world.owner.listings == 1)
    }
}
