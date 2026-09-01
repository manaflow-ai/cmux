// Pins the optional per-build instance-tag dimension of the relay connect:
// header normalization (release lanes and unusable values stay untagged, so
// production object names never move), the host link sending its own build
// tag, and the pairing's tag flowing through the transport request into the
// client dial. Wire rule source of truth: workers/mobile-relay/src/protocol.ts
// (parseInstanceTag), mirrored by RelayConnectAuth.normalizedInstanceTag.

import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxRelayTransport

/// Captures the headers handed to a RelayConnectionFactory.
private final class HeaderCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String]?

    func set(_ headers: [String: String]) {
        lock.lock()
        value = headers
        lock.unlock()
    }

    var captured: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func relayFarDeadline() -> Double {
    (Date().timeIntervalSince1970 + 3600) * 1000
}

@Suite struct RelayInstanceTagNormalizationTests {
    @Test func devTagsNormalizeToTrimmedLowercase() {
        #expect(RelayConnectAuth.normalizedInstanceTag(" Feat-Relay.2 ") == "feat-relay.2")
        #expect(RelayConnectAuth.normalizedInstanceTag("feat-x") == "feat-x")
    }

    @Test func absentAndBlankStayUntagged() {
        #expect(RelayConnectAuth.normalizedInstanceTag(nil) == nil)
        #expect(RelayConnectAuth.normalizedInstanceTag("") == nil)
        #expect(RelayConnectAuth.normalizedInstanceTag("   ") == nil)
    }

    @Test func releaseLanesStayUntagged() {
        for lane in RelayProtocol.untaggedInstanceTags {
            #expect(RelayConnectAuth.normalizedInstanceTag(lane) == nil)
            #expect(RelayConnectAuth.normalizedInstanceTag(lane.uppercased()) == nil)
        }
    }

    @Test func unusableValuesStayUntaggedInsteadOfFailingTheDial() {
        #expect(RelayConnectAuth.normalizedInstanceTag("has:colon") == nil)
        #expect(RelayConnectAuth.normalizedInstanceTag("-leading-dash") == nil)
        #expect(RelayConnectAuth.normalizedInstanceTag("sp ace") == nil)
        let overlong = String(repeating: "a", count: RelayProtocol.maxInstanceTagChars + 1)
        #expect(RelayConnectAuth.normalizedInstanceTag(overlong) == nil)
        let longest = String(repeating: "a", count: RelayProtocol.maxInstanceTagChars)
        #expect(RelayConnectAuth.normalizedInstanceTag(longest) == longest)
    }

    @Test func headersCarryTheTagOnlyWhenItNamesAnObject() {
        let tagged = RelayConnectAuth.headers(
            accessToken: "token-1",
            role: .host,
            hostDeviceID: "HOST-1",
            deviceID: "HOST-1",
            instanceTag: "Feat-X"
        )
        #expect(tagged[RelayProtocol.instanceTagHeaderName] == "feat-x")
        #expect(tagged[RelayProtocol.hostDeviceHeaderName] == "host-1")

        let untagged = RelayConnectAuth.headers(
            accessToken: "token-1",
            role: .host,
            hostDeviceID: "HOST-1",
            deviceID: "HOST-1",
            instanceTag: "default"
        )
        #expect(untagged[RelayProtocol.instanceTagHeaderName] == nil)

        let absent = RelayConnectAuth.headers(
            accessToken: "token-1",
            role: .client,
            hostDeviceID: "host-1",
            deviceID: "phone-1"
        )
        #expect(absent[RelayProtocol.instanceTagHeaderName] == nil)
    }
}

@Suite struct RelayInstanceTagDialTests {
    @Test func hostLinkDialsWithItsOwnBuildTag() async throws {
        let fake = FakeRelayConnection(
            welcome: RelayWelcome(v: 2, role: .host, sessionId: 0, deadline: relayFarDeadline(), hostPresent: true)
        )
        let capture = HeaderCapture()
        let link = RelayHostLink(
            hostDeviceID: "host-1",
            instanceTag: "feat-x",
            accessToken: { "stack-token-mac" },
            makeConnection: { _, headers in
                capture.set(headers)
                return fake
            },
            onClientSession: { _ in }
        )
        let runTask = Task { await link.run() }
        try await waitUntil("host dial headers captured") {
            capture.captured != nil
        }
        #expect(capture.captured?[RelayProtocol.instanceTagHeaderName] == "feat-x")

        await link.stop()
        await fake.finishEvents()
        runTask.cancel()
    }

    @Test func clientTransportDialsWithThePairingTag() async throws {
        let fake = FakeRelayConnection(
            welcome: RelayWelcome(v: 2, role: .client, sessionId: 4, deadline: relayFarDeadline(), hostPresent: true)
        )
        let capture = HeaderCapture()
        let transport = RelayClientByteTransport(
            hostDeviceID: "host-1",
            hostInstanceTag: "feat-x",
            deviceID: { "phone-1" },
            accessToken: { "stack-token-phone" },
            makeConnection: { _, headers in
                capture.set(headers)
                return fake
            }
        )
        try await transport.connect()
        #expect(capture.captured?[RelayProtocol.instanceTagHeaderName] == "feat-x")
        await transport.close()
    }

    @Test func factoryPassesTheRequestInstanceTagThrough() async throws {
        let fake = FakeRelayConnection(
            welcome: RelayWelcome(v: 2, role: .client, sessionId: 4, deadline: relayFarDeadline(), hostPresent: true)
        )
        let capture = HeaderCapture()
        let factory = RelayClientTransportFactory(
            deviceID: { "phone-1" },
            accessToken: { "stack-token-phone" },
            makeConnection: { _, headers in
                capture.set(headers)
                return fake
            }
        )
        let route = try CmxAttachRoute(
            id: "relay",
            kind: .websocket,
            endpoint: .url("wss://relay.test/v1/connect"),
            priority: 0
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "HOST-1",
            expectedPeerInstanceTag: "Feat-X",
            authorizationMode: .transportAdmission
        )
        let transport = try factory.makeTransport(for: request)
        try await transport.connect()
        #expect(capture.captured?[RelayProtocol.instanceTagHeaderName] == "feat-x")
        await transport.close()
    }

    @Test func requestWithoutTagDialsUntagged() async throws {
        let fake = FakeRelayConnection(
            welcome: RelayWelcome(v: 2, role: .client, sessionId: 4, deadline: relayFarDeadline(), hostPresent: true)
        )
        let capture = HeaderCapture()
        let factory = RelayClientTransportFactory(
            deviceID: { "phone-1" },
            accessToken: { "stack-token-phone" },
            makeConnection: { _, headers in
                capture.set(headers)
                return fake
            }
        )
        let route = try CmxAttachRoute(
            id: "relay",
            kind: .websocket,
            endpoint: .url("wss://relay.test/v1/connect"),
            priority: 0
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "host-1",
            authorizationMode: .transportAdmission
        )
        let transport = try factory.makeTransport(for: request)
        try await transport.connect()
        #expect(capture.captured != nil)
        #expect(capture.captured?[RelayProtocol.instanceTagHeaderName] == nil)
        await transport.close()
    }
}
