@testable import CmuxNextDevices
import Foundation
import Testing

/// Build spaces on the device hub (docs/device-hub/PROTOCOL.md "Build spaces"). Every DEV Mac and Debug iPhone of every
/// tag uses the one dev hub, and the hub kept one set of devices per account, so a tag's iPhone listed every build's Mac.
/// The hub now keeps one per build space; these check the Mac's side: a tagged dev build names its space on every call,
/// NIGHTLY names none, a DEV build with no usable tag sends nothing, and each space names this Mac apart.
@Suite struct DeviceHubBuildSpaceTests {
    static let me = ["GET /v1/me": (200, #"{"userId":"user-1","plan":"paid"}"#)]

    @Test func aTaggedDevBuildNamesItsSpaceOnEveryCallAndItsSocket() async throws {
        let identity = DeviceIdentity.software()
        let hub = StubHub.routes(Self.me)
        let client = makeClient(hub, identity: identity, buildSpace: .dev("dev:tag-a"))
        _ = try await client.me()
        // The account exchange (the hub binds the session to it) and the signed call.
        #expect(hub.requests.map(\.url.path) == ["/v1/auth/stack", "/v1/me"])
        #expect(hub.requests.map { $0.header("X-Cmux-Build-Space") } == ["dev:tag-a", "dev:tag-a"])
        // The header is not part of what the device signs: the signature still verifies.
        let call = try #require(hub.requests.last)
        let canonical = DeviceRequestSigner.canonical(method: call.method, pathAndQuery: call.pathAndQuery, timestamp: 1_800_000_000, body: call.body)
        #expect(DeviceIdentity.verify(signature: call.header("X-Device-Sig") ?? "", of: Data(canonical.utf8), signingKey: identity.signingKey))
        let socket = try await client.userSocketHandshake().request
        #expect(socket.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:tag-a")
    }

    @Test func nightlyAndReleaseNameNoSpace() async throws {
        let hub = StubHub.routes(Self.me)
        let client = makeClient(hub)
        _ = try await client.me()
        #expect(hub.requests.count == 2 && hub.requests.allSatisfy { $0.header("X-Cmux-Build-Space") == nil })
        #expect(try await client.userSocketHandshake().headers["X-Cmux-Build-Space"] == nil)
    }

    /// A DEV build with no usable tag never lands among NIGHTLY's devices: nothing reaches the hub.
    @Test func aDevBuildWithNoUsableTagMakesNoHubCall() async throws {
        let hub = StubHub.routes(Self.me)
        let client = makeClient(hub, buildSpace: .unusable)
        await #expect(throws: DeviceHubError.notConfigured) { try await client.me() }
        await #expect(throws: DeviceHubError.notConfigured) { try await client.userSocketHandshake() }
        await #expect(throws: DeviceHubError.notConfigured) { try await client.registerDevice(name: "Studio", platform: .macos) }
        #expect(hub.requests.isEmpty)
    }

    /// Each space names this Mac apart (an Always answer about it never crosses builds), the app and its cmux Remote of
    /// one space name it alike, and the default space keeps the value every build sent before build spaces.
    @Test func eachBuildSpaceNamesThisMacApart() async throws {
        let key = Data(repeating: 7, count: 32), uuid = "8A1C3F2E-0D4B-4C5A-9E7F-112233445566"
        let nightly = DeviceMachine(hardwareUUID: uuid, secret: key)
        let a = DeviceMachine(hardwareUUID: uuid, secret: key, buildSpace: "dev:tag-a")
        let b = DeviceMachine(hardwareUUID: uuid, secret: key, buildSpace: "dev:tag-b")
        #expect(a.id == DeviceMachine(hardwareUUID: uuid, secret: key, buildSpace: "dev:tag-a").id)
        #expect(Set([nightly.id, a.id, b.id].compactMap(\.self)).count == 3)
        #expect(a.id?.count == 64 && a.id?.contains("tag-a") == false)
        #expect(DeviceMachine.current(in: .nightly) == DeviceMachine.current)
        #expect(DeviceMachine.current(in: .unusable) == DeviceMachine.current)

        let hub = StubHub.routes(["POST /v1/devices": (200, #"{"device":{"id":"6f1c2a4e-0d3b-4c5a-9e7f-112233445566","name":"Studio","platform":"macos","macScreenShared":0,"online":true}}"#)])
        _ = try await makeClient(hub, buildSpace: .dev("dev:tag-a")).registerDevice(name: "Studio", platform: .macos)
        let body = try #require(hub.requests.last?.jsonBody)
        #expect(body["machine"] as? String == DeviceMachine.current(in: .dev("dev:tag-a")).id)
        #expect(DeviceMachine.current.id == nil || DeviceMachine.current(in: .dev("dev:tag-a")).id != DeviceMachine.current.id)
    }
}
