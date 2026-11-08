import CryptoKit
import Foundation
import Testing
import CmuxIrohTransport
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct LegacyCompatibilityRegistrationTests {
    @Test(arguments: [false, true])
    func upgradePreservesOtherMacsAndStableWhileRepairingNightly(alreadyDuplicated: Bool) async throws {
        let backend = CompatibilityRegistrationFixture(alreadyDuplicated: alreadyDuplicated)
        let server = try await IrxStaleKeepAliveHTTPServer.start(requestHandler: { backend.handle($0) })
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LegacyCompatibilityService.Configuration(
            brokerBaseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            clientNamespace: backend.namespace, tag: "nightly", platform: .mac,
            displayName: "Same Mac", cacheDirectory: directory, accountID: "test-account")
        let identity = LegacyCompatibilityService.compatibilityIdentity(
            from: backend.v2, deviceID: backend.physicalID)
        for _ in 0..<2 {
            let service = try LegacyCompatibilityService(configuration: configuration, identity: identity,
                previousDeviceID: backend.v2.deviceID,
                accessTokenPair: { ("test-access", "test-refresh") },
                journal: IrxJournal(subsystem: "dev.cmux.tests", category: "identity-migration"))
            try await service.start()
            let discovered = try #require(await service.snapshot().discovery)
            #expect(discovered.bindings.count == 3)
            let nightly = try #require(discovered.bindings.first { $0.tag == "nightly" && $0.deviceID == backend.physicalID })
            #expect(nightly.deviceID == backend.physicalID)
            #expect(nightly.endpointID.endpointID == backend.v2.endpointIDHex)
            #expect(discovered.bindings.first { $0.deviceID == backend.otherID }?.endpointID.endpointID == backend.other.endpointIDHex)
            #expect(discovered.bindings.first { $0.tag == "default" }?.endpointID.endpointID == backend.stable.endpointIDHex)
            await service.stop()
        }
        #expect(backend.revokedDeviceIDs == (alreadyDuplicated ? [backend.v2.deviceID] : []))
    }

    @Test func lostRevocationReplyRecoversOnTheNextStartup() async throws {
        let backend = CompatibilityRegistrationFixture(alreadyDuplicated: true, loseRevocationReply: true)
        let server = try await IrxStaleKeepAliveHTTPServer.start(requestHandler: { backend.handle($0) })
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func service() throws -> LegacyCompatibilityService {
            try LegacyCompatibilityService(configuration: .init(
                brokerBaseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
                clientNamespace: backend.namespace, tag: "nightly", platform: .mac,
                displayName: "Same Mac", cacheDirectory: directory, accountID: "test-account"),
                identity: LegacyCompatibilityService.compatibilityIdentity(from: backend.v2, deviceID: backend.physicalID),
                previousDeviceID: backend.v2.deviceID, accessTokenPair: { ("test-access", "test-refresh") },
                journal: IrxJournal(subsystem: "dev.cmux.tests", category: "migration-interrupted"))
        }
        let interrupted = try service()
        await #expect(throws: (any Error).self) { try await interrupted.start() }
        #expect(backend.physicalNightlyEndpoint == backend.old.endpointIDHex)
        #expect(backend.revokedDeviceIDs == [backend.v2.deviceID])
        await interrupted.stop()
        let restarted = try service()
        try await restarted.start()
        let discovery = try #require(await restarted.snapshot().discovery)
        #expect(discovery.bindings.filter { $0.tag == "nightly" && $0.deviceID != backend.otherID }.map(\.deviceID) == [backend.physicalID])
        #expect(backend.physicalNightlyEndpoint == backend.v2.endpointIDHex)
        #expect(backend.revokedDeviceIDs == [backend.v2.deviceID])
        await restarted.stop()
    }

    @Test func failedRevocationDoesNotPublishOrEraseTheOriginalComputer() async throws {
        let backend = CompatibilityRegistrationFixture(alreadyDuplicated: true, rejectRevocation: true)
        let server = try await IrxStaleKeepAliveHTTPServer.start(requestHandler: { backend.handle($0) })
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try LegacyCompatibilityService(configuration: .init(
            brokerBaseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            clientNamespace: backend.namespace, tag: "nightly", platform: .mac,
            displayName: "Same Mac", cacheDirectory: directory, accountID: "test-account"),
            identity: LegacyCompatibilityService.compatibilityIdentity(from: backend.v2, deviceID: backend.physicalID),
            previousDeviceID: backend.v2.deviceID, accessTokenPair: { ("test-access", "test-refresh") },
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "migration-denied"))
        await #expect(throws: CmxIrohTrustBrokerClientError.rejected(statusCode: 403, code: "test_revocation_denied")) {
            try await service.start()
        }
        #expect(await service.snapshot().binding == nil)
        #expect(backend.revokedDeviceIDs.isEmpty)
        #expect(backend.physicalNightlyEndpoint == backend.old.endpointIDHex)
        await service.stop()
    }
}

/// A real loopback HTTP broker exercising the production client, signer,
/// challenge flow, cached authorization, self-revocation and discovery. Slots
/// follow the account directory's device + namespace + tag uniqueness rule.
private final class CompatibilityRegistrationFixture: @unchecked Sendable {
    let physicalID = "11111111-1111-4111-8111-111111111111"
    let otherID = "33333333-3333-4333-8333-333333333333"
    let namespace = "mac:com.cmuxterm.app.nightly"
    let v2 = IrxIdentity(privateKeyData: Data(repeating: 2, count: 32),
        deviceID: "22222222-2222-4222-8222-222222222222", appInstanceID: "v2-tuple")
    let old = IrxIdentity(privateKeyData: Data(repeating: 3, count: 32), deviceID: "old", appInstanceID: "old")
    let stable = IrxIdentity(privateKeyData: Data(repeating: 4, count: 32), deviceID: "stable", appInstanceID: "stable")
    let other = IrxIdentity(privateKeyData: Data(repeating: 5, count: 32), deviceID: "other", appInstanceID: "other")
    private let lock = NSLock()
    private var bindings: [[String: Any]] = []
    private var revoked: [String] = []
    private let rejectRevocation: Bool
    private var loseRevocationReply: Bool

    init(alreadyDuplicated: Bool, rejectRevocation: Bool = false, loseRevocationReply: Bool = false) {
        self.rejectRevocation = rejectRevocation
        self.loseRevocationReply = loseRevocationReply
        bindings = [binding(deviceID: physicalID, endpoint: old.endpointIDHex, tag: "nightly"),
                    binding(deviceID: physicalID, endpoint: stable.endpointIDHex, tag: "default"),
                    binding(deviceID: otherID, endpoint: other.endpointIDHex, tag: "nightly")]
        if alreadyDuplicated {
            bindings.append(binding(deviceID: v2.deviceID, endpoint: v2.endpointIDHex, tag: "nightly"))
        }
    }

    var revokedDeviceIDs: [String] { lock.withLock { revoked } }
    var physicalNightlyEndpoint: String? {
        lock.withLock { bindings.first { $0["device_id"] as? String == physicalID && $0["tag"] as? String == "nightly" }?["endpoint_id"] as? String }
    }

    func handle(_ bytes: Data) -> IrxStaleKeepAliveHTTPServer.RequestAction {
        lock.lock()
        defer { lock.unlock() }
        do {
            let split = try #require(bytes.range(of: Data("\r\n\r\n".utf8)))
            let lines = String(decoding: bytes[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let request = try #require(lines.first).components(separatedBy: " ")
            let body = Data(bytes[split.upperBound...])
            let fields = body.isEmpty ? [:] : try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            if request[1].hasPrefix("/api/devices/iroh/challenge") {
                return reply(["challenge_id": UUID().uuidString.lowercased(),
                    "nonce": base64(Data(repeating: 1, count: 32)), "expires_at": "2099-01-01T00:00:00Z"])
            }
            if request[0] == "POST", request[1] == "/api/devices/iroh/register" {
                let payload = try decode(try #require(fields["payload"] as? String))
                let value = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                let endpoint = try #require(value["endpointId"] as? String)
                let transcript = "cmux/iroh/device-registration/v1\n\(try #require(fields["challengeId"] as? String))\n\(try #require(fields["nonce"] as? String))\n\(SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())"
                try verify(signature: try #require(fields["signature"] as? String), transcript: transcript, endpoint: endpoint)
                let deviceID = try #require(value["deviceId"] as? String)
                let tag = try #require(value["tag"] as? String)
                let namespace = try #require(value["clientNamespace"] as? String)
                let slot = bindings.firstIndex { $0["device_id"] as? String == deviceID && $0["tag"] as? String == tag && $0["client_namespace"] as? String == namespace }
                if bindings.enumerated().contains(where: { $0.offset != slot && $0.element["endpoint_id"] as? String == endpoint }) {
                    return reply(["error": "endpoint_already_bound"], status: 409)
                }
                var record = binding(deviceID: deviceID, endpoint: endpoint, tag: tag)
                record["app_instance_id"] = value["appInstanceId"]
                if let slot {
                    if bindings[slot]["endpoint_id"] as? String == endpoint { record["binding_id"] = bindings[slot]["binding_id"] }
                    bindings[slot] = record
                } else { bindings.append(record) }
                return reply(["binding": record, "relay": ["status": "not_requested"]])
            }
            let headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return (pair[0].lowercased(), pair[1].trimmingCharacters(in: .whitespaces))
            })
            let callerID = try #require(headers["x-cmux-iroh-binding-id"])
            let caller = try #require(bindings.first { $0["binding_id"] as? String == callerID })
            let transcript = "cmux/iroh/binding-request/v1\n\(callerID)\n\(request[0])\n\(request[1].split(separator: "?", maxSplits: 1)[0].dropFirst())\n\(try #require(headers["x-cmux-iroh-request-time"]))\n\(SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())"
            try verify(signature: try #require(headers["x-cmux-iroh-request-signature"]), transcript: transcript,
                endpoint: try #require(caller["endpoint_id"] as? String))
            if request[0] == "DELETE" {
                if rejectRevocation { return reply(["error": "test_revocation_denied"], status: 403) }
                #expect(fields["bindingId"] as? String == callerID)
                revoked.append(try #require(caller["device_id"] as? String))
                bindings.removeAll { $0["binding_id"] as? String == callerID }
                if loseRevocationReply {
                    loseRevocationReply = false
                    return .resetConnection
                }
                return reply(["revoked": true, "lan_rendezvous_rotated": true])
            }
            return reply(["route_contract_version": 1, "bindings": bindings, "relay_fleet": ["https://relay.example.com/"],
                "lan_rendezvous": ["generation": 1, "key": base64(Data(repeating: 5, count: 32))],
                "grant_verification_keys": ["version": 1, "current_kid": "test", "keys": []]])
        } catch {
            if !(error is ExpectationFailedError) { Issue.record(error) }
            return reply(["error": "test_invalid_request"], status: 400)
        }
    }

    private func binding(deviceID: String, endpoint: String, tag: String) -> [String: Any] {
        ["binding_id": UUID().uuidString.lowercased(), "device_id": deviceID,
         "app_instance_id": UUID().uuidString.lowercased(), "client_namespace": namespace,
         "tag": tag, "platform": "mac", "display_name": "Same Mac", "endpoint_id": endpoint,
         "identity_generation": 1, "pairing_enabled": true, "capabilities": [LegacyCompatibilityService.v2Capability],
         "path_hints": [], "last_seen_at": "2026-09-15T00:00:00Z"]
    }
    private func reply(_ value: [String: Any], status: Int = 200) -> IrxStaleKeepAliveHTTPServer.RequestAction {
        .reply(status: status, body: try! JSONSerialization.data(withJSONObject: value))
    }
    private func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func decode(_ string: String) throws -> Data {
        let value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return try #require(Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4)))
    }
    private func verify(signature: String, transcript: String, endpoint: String) throws {
        let bytes = stride(from: 0, to: endpoint.count, by: 2).map { index in
            UInt8(endpoint.dropFirst(index).prefix(2), radix: 16)!
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(bytes))
        try #require(key.isValidSignature(decode(signature), for: Data(transcript.utf8)))
    }
}
