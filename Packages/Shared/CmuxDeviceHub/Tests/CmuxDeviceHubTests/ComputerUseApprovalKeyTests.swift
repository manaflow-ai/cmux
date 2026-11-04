@testable import CmuxDeviceHub
import CryptoKit
import Foundation
import Security
import Testing

/// The approval key (docs/computer-use-approvals.md, "Device hub approvals"): Allows are
/// signed only by a key whose access control asks for the person; Deny stays on the device key.
@Suite struct ComputerUseApprovalKeyTests {
    /// What a factory was asked to make, and how often the person was asked.
    final class Recorder: Sendable {
        let made = Mutex<[(flags: SecAccessControlCreateFlags, protection: String)]>([])
        let checks = Mutex<[String]>([])

        var factory: ComputerUseApprovalKeyFactory {
            ComputerUseApprovalKeyFactory(
                make: { [made] flags, protection in
                    made.withLock { $0.append((flags, protection)) }
                    return SoftwareApprovalKey(key: P256.Signing.PrivateKey())
                },
                restore: { raw in (try? P256.Signing.PrivateKey(rawRepresentation: raw)).map(SoftwareApprovalKey.init) },
                checkPresence: { [checks] reason in
                    checks.withLock { $0.append(reason) }
                    return .unchecked()
                }
            )
        }
    }

    @Test func aNewKeyNeedsUserPresenceOnEveryUse() throws {
        #expect(ComputerUseApprovalKey.accessControlFlags == [.privateKeyUsage, .userPresence])
        #expect(ComputerUseApprovalKey.protection == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let recorder = Recorder()
        _ = try ComputerUseApprovalKey(making: recorder.factory)
        let made = recorder.made.withLock { $0 }
        #expect(made.count == 1)
        #expect(made.first?.flags == [.privateKeyUsage, .userPresence])
        #expect(made.first?.protection == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func authorizingAsksThePersonOnceAndSignsTheUnchangedMessage() async throws {
        let vectors = try HubTestVectors.load()
        let digest = try #require(vectors.approvalRequest.request.digest)
        let recorder = Recorder()
        let key = try ComputerUseApprovalKey(making: recorder.factory)
        let authorization = try await key.authorize(reason: "Allow Claude to use Text Editor")
        #expect(recorder.checks.withLock { $0 } == ["Allow Claude to use Text Editor"])
        #expect(authorization.publicKey == key.publicKey)
        let first = try authorization.signApproval(digest: digest, decision: .once)
        #expect(DeviceIdentity.verifyApproval(signature: first, digest: digest, decision: .once, signingKey: key.publicKey))
        // One Face ID check signs one Allow: not a second, not another decision.
        #expect(throws: ComputerUseApprovalKey.Failure.authorizationUsed) {
            _ = try authorization.signApproval(digest: digest, decision: .always)
        }
        for vector in vectors.approvalDecisions where vector.decision != .deny {
            // The canonical message is the one every device signs: "cmux-cu-approval-v1\n<digest>\n<decision>".
            #expect(vector.decision.signatureMessage(digest: digest) == vector.message)
            #expect(vector.message == "cmux-cu-approval-v1\n\(digest)\n\(vector.decision.rawValue)")
            let sig = try await key.authorize(reason: "r").signApproval(digest: digest, decision: vector.decision)
            #expect(DeviceIdentity.verify(signature: sig, of: Data(vector.message.utf8), signingKey: key.publicKey))
        }
    }

    @Test func theFingerprintIsTheSHA256OfTheX963Key() throws {
        let key = try ComputerUseApprovalKey(making: .software)
        let bytes = try #require(Data(base64Encoded: key.publicKey))
        #expect(bytes.count == 65 && bytes.first == 0x04)
        #expect(key.fingerprint == hexString(Data(SHA256.hash(data: bytes))))
        #expect(key.fingerprint == DeviceIdentity.fingerprint(signingKey: key.publicKey))
    }

    @Test func allowsSignWithTheApprovalKeyAndDenyWithTheDeviceKey() async throws {
        let vectors = try HubTestVectors.load()
        let digest = try #require(vectors.approvalRequest.request.digest)
        let approvalKey = try ComputerUseApprovalKey(making: .software)
        let identity = DeviceIdentity.software(approvalKey: approvalKey)
        let approval = try vectorApproval(id: "ap1")
        let hub = StubHub.routes(["POST /v1/approvals/ap1/decision": (200, #"{"approval":\#(approval)}"#)])
        let client = makeClient(hub, identity: identity)
        for decision in ComputerUseDecision.allCases {
            _ = try await client.decide(id: "ap1", decision: decision, digest: digest,
                                        authorization: try await approvalKey.authorize(reason: "r"))
        }
        let sent = hub.requests.filter { $0.url.path == "/v1/approvals/ap1/decision" }.compactMap(\.jsonBody)
        #expect(sent.compactMap { $0["decision"] as? String } == ["once", "session", "always", "deny"])
        for body in sent {
            let decision = try #require(ComputerUseDecision(rawValue: body["decision"] as? String ?? ""))
            let sig = try #require(body["sig"] as? String)
            let expected = decision == .deny ? identity.signingKey : approvalKey.publicKey
            let other = decision == .deny ? approvalKey.publicKey : identity.signingKey
            #expect(DeviceIdentity.verifyApproval(signature: sig, digest: digest, decision: decision, signingKey: expected))
            #expect(!DeviceIdentity.verifyApproval(signature: sig, digest: digest, decision: decision, signingKey: other))
        }
    }

    @Test func anAllowWithoutAnAuthorizationIsNeverSent() async throws {
        let hub = StubHub.routes([:])
        let client = makeClient(hub, identity: .software(approvalKey: try ComputerUseApprovalKey(making: .software)))
        for decision in [ComputerUseDecision.once, .session, .always] {
            await #expect(throws: DeviceHubError.self) {
                _ = try await client.decide(id: "ap1", decision: decision, digest: "d")
            }
        }
        #expect(hub.requests.isEmpty)
    }

    @Test func registrationSendsTheApprovalKeyOnlyWhenThereIsOne() async throws {
        let approvalKey = try ComputerUseApprovalKey(making: .software)
        let device = #"{"device":{"id":"6f1c2a4e-0d3b-4c5a-9e7f-112233445566","name":"Phone","platform":"ios","approvalKey":"\#(approvalKey.publicKey)"}}"#
        let hub = StubHub.routes(["POST /v1/devices": (200, device)])
        let registered = try await makeClient(hub, identity: .software(approvalKey: approvalKey)).registerDevice(name: "Phone", platform: .ios)
        #expect(registered.approvalKey == approvalKey.publicKey)
        #expect(hub.requests.last?.jsonBody?["approvalKey"] as? String == approvalKey.publicKey)

        let plain = StubHub.routes(["POST /v1/devices": (200, device)])
        _ = try await makeClient(plain).registerDevice(name: "Studio", platform: .macos)
        #expect(plain.requests.last?.jsonBody?.keys.contains("approvalKey") == false)
    }

    @Test func aDecisionVerifiesOnlyWithTheDecidersKeyForIt() async throws {
        let digest = try #require(try HubTestVectors.load().approvalRequest.request.digest)
        let approvalKey = try ComputerUseApprovalKey(making: .software)
        let identity = DeviceIdentity.software(approvalKey: approvalKey)
        let decider = HubDevice(id: identity.id, name: "Phone", platform: .ios, signingKey: identity.signingKey,
                                approvalKey: approvalKey.publicKey)
        let allowSig = try await approvalKey.authorize(reason: "r").signApproval(digest: digest, decision: .always)
        let allow = ComputerUseApprovalDecided(id: "a", decision: .always, digest: digest, deciderId: identity.id, sig: allowSig)
        #expect(allow.verifies(decider: decider))
        // The same Allow signed by the device key (no Face ID) is refused.
        let forged = ComputerUseApprovalDecided(id: "a", decision: .always, digest: digest, deciderId: identity.id,
                                                sig: try identity.signApproval(digest: digest, decision: .always))
        #expect(!forged.verifies(decider: decider))
        var noKey = decider
        noKey.approvalKey = nil
        #expect(!allow.verifies(decider: noKey))
        let deny = ComputerUseApprovalDecided(id: "a", decision: .deny, digest: digest, deciderId: identity.id,
                                              sig: try identity.signApproval(digest: digest, decision: .deny))
        #expect(deny.verifies(decider: decider))
    }

    @Test func anotherApprovalKeyOnTheHubMakesANewDevice() {
        #expect(DeviceHub.renewsIdentity(.approvalKeyMismatch))
        #expect(DeviceHub.renewsIdentity(.deviceKeyMismatch) && DeviceHub.renewsIdentity(.deviceRemoved))
        #expect(!DeviceHub.renewsIdentity(.approvalKeyRequired))
    }
}
