// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteScreenSharing
import CmuxDeviceHub
import CmuxRemoteWire
import CryptoKit
import Foundation
import os
import Testing

/// The worker and app can both observe the same device-hub ticket. Once the
/// app channel is present, only the app may host or approve; the worker must
/// stay a relay and leave the ticket for the app-owned host.
@MainActor
@Suite struct ScreenSharingOwnershipTests {
    private struct SoftwareKeys: DeviceKeyMaterial {
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
        var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
        func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
        func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data { Data() }
    }

    private static func testHub() -> DeviceHub {
        let identity = DeviceIdentity(deviceID: UUID(), keys: SoftwareKeys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.example")!, identity: identity,
                                     source: .deviceRenewal(userID: "test-user"))
        return DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "Test")
    }

    private final class OneShotConnection: Sendable, DeviceHubSocketConnection {
        let text: String
        init(text: String) { self.text = text }
        func receive() async throws -> String { text }
        func send(_ text: String) async throws {}
        func close() {}
    }

    @Test func appChannelMakesWorkerRelayOnlyAndRestoresAfterDisconnect() {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "cmux-screen-sharing-test-\(UUID().uuidString).json").path
        let agent = DeviceAgent(keychainScope: "com.cmuxterm.test", statePath: path, headless: true)
        #expect(agent.mayHostSessions)

        agent.setRelayOnly(true)
        #expect(agent.relayOnly)
        #expect(!agent.mayHostSessions)
        #expect(agent.banner.current == nil)

        agent.setRelayOnly(false)
        #expect(!agent.relayOnly)
        #expect(agent.mayHostSessions)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func workerChannelCountKeepsRelayOnlyUntilTheLastAppChannelCloses() {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-screen-worker-\(UUID().uuidString)")
        let worker = ScreenSharingWorker(
            layout: RemoteHostLayout(directory: root.appending(path: "layout").path),
            stateDirectory: root.appending(path: "state").path,
            keychainScope: "com.cmuxterm.test",
            headless: true
        )
        #expect(worker.appChannels == 0)
        worker.appChannelOpened()
        worker.appChannelOpened()
        #expect(worker.appChannels == 2)
        #expect(worker.agent.relayOnly)
        worker.appChannelClosed()
        #expect(worker.appChannels == 1)
        #expect(worker.agent.relayOnly)
        worker.appChannelClosed()
        #expect(worker.appChannels == 0)
        #expect(!worker.agent.relayOnly)
    }

    @Test func workerStopSessionRefusesWhileAppOwnsHostLease() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-screen-worker-stop-\(UUID().uuidString)")
        let worker = ScreenSharingWorker(
            layout: RemoteHostLayout(directory: root.appending(path: "layout").path),
            stateDirectory: root.appending(path: "state").path,
            keychainScope: "com.cmuxterm.test",
            headless: true
        )
        worker.appChannelOpened()
        let response = try #require(try JSONSerialization.jsonObject(with: await worker.handle("stop_session", [:], id: 1)) as? [String: Any])
        #expect(response["ok"] as? Bool == false)
        #expect((response["error"] as? [String: Any])?["code"] as? String == "screen.app_host")
        #expect((response["error"] as? [String: Any])?["message"] as? String == "the cmux app owns Mac Screen sharing")
        worker.appChannelClosed()
    }

    @Test func relayOnlyDropsHostTicketWithoutInvokingWorkerHost() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "cmux-screen-sharing-ticket-\(UUID().uuidString).json").path
        let agent = DeviceAgent(keychainScope: "com.cmuxterm.test", statePath: path, headless: true)
        var served = 0
        agent.serveTicket = { _ in served += 1 }
        let ticket = SessionTicket(sessionId: "s1", ticket: "jws", signalURL: try #require(URL(string: "wss://hub.example/ws")),
                                    ice: [], peer: .init(id: "viewer", name: "Viewer", signingKey: "key"), role: .host, scope: .view)
        agent.setRelayOnly(true)
        agent.handle(.sessionTicket(ticket))
        #expect(served == 0)
        agent.setRelayOnly(false)
        agent.handle(.sessionTicket(ticket))
        #expect(served == 1)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func relayedTicketRemainsForAppHostWhileWorkerDropsIt() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "cmux-screen-sharing-relay-\(UUID().uuidString).json").path
        let agent = DeviceAgent(keychainScope: "com.cmuxterm.test", statePath: path, headless: true)
        var served = 0
        agent.serveTicket = { _ in served += 1 }
        agent.setRelayOnly(true)
        let ticketText = #"{"type":"session.ticket","sessionId":"s1","ticket":"jws","signalURL":"wss://hub.example/ws","ice":[],"peer":{"id":"viewer","name":"Viewer","signingKey":"key"},"role":"host","scope":"view"}"#
        let relay = PushRelay()
        let subscriber = ObjectIdentifier(NSObject())
        let relayed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let received = OSAllocatedUnfairLock<String?>(initialState: nil)
        relay.add(subscriber) { line in
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let text = object["text"] as? String { received.withLock { $0 = text } }
            relayed.continuation.yield(())
            return true
        }
        _ = try await RelayingConnection(inner: OneShotConnection(text: ticketText), relay: relay).receive()
        let sawRelay = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                var iterator = relayed.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(sawRelay)
        let pushText = try #require(received.withLock { $0 })
        agent.handle(try #require(DeviceHubPush(text: pushText)))
        #expect(served == 0)
        relay.remove(subscriber)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func relayOnlyRejectsStaleApprovalDecision() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "cmux-screen-sharing-approval-\(UUID().uuidString).json").path
        let agent = DeviceAgent(keychainScope: "com.cmuxterm.test", statePath: path, headless: true)
        agent.setRelayOnly(true)
        let request = SessionRequest(id: "ask", viewerId: "viewer", viewerName: "Viewer", scope: .view)
        do {
            try await agent.banner.decide(request, .once)
            Issue.record("relay-only worker accepted an approval decision")
        } catch let error as DeviceHubError {
            #expect(error.code == .sessionNotPending)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func ownershipTakeoverAfterDecisionStartsSkipsRememberedPermission() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "cmux-screen-sharing-approval-race-\(UUID().uuidString).json").path
        let agent = DeviceAgent(keychainScope: "com.cmuxterm.test", statePath: path, headless: true)
        agent.setHub(Self.testHub())
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var remembered = 0
        agent.decideApproval = { _, _, _, _ in
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }
        agent.rememberApproval = { _, _, _ in remembered += 1 }
        let request = SessionRequest(id: "ask", viewerId: "viewer", viewerName: "Viewer", scope: .view)
        let decision = Task { try await agent.banner.decide(request, .alwaysFull) }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        agent.setRelayOnly(true)
        release.continuation.yield(())
        try await decision.value
        #expect(remembered == 0)
        try? FileManager.default.removeItem(atPath: path)
    }
}
