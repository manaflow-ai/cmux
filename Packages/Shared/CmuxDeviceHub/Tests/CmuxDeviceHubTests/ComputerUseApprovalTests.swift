import CryptoKit
@testable import CmuxDeviceHub
import Foundation
import Testing

/// The shared vectors every device hub client reproduces (schemas/device-hub/test-vectors.json).
struct HubTestVectors: Decodable {
    struct Key: Decodable {
        var privateKeyHex: String
        var signingKey: String
    }

    struct RequestSigning: Decodable {
        var method: String
        var pathAndQuery: String
        var ts: String
        var body: String
        var bodySha256: String
        var canonical: String
        var sig: String
        var sigHighS: String
        var lowSHex: String
    }

    struct CanonicalCase: Decodable {
        var value: HubJSON
        var canonical: String
        var sha256: String
    }

    struct ApprovalRequest: Decodable {
        var request: ComputerUseApprovalRequest
    }

    struct Decision: Decodable {
        var decision: ComputerUseDecision
        var message: String
        var sig: String
        var sigHighS: String
        var lowSHex: String
    }

    var key: Key
    var requestSigning: [RequestSigning]
    var canonicalJson: [CanonicalCase]
    var approvalRequest: ApprovalRequest
    var approvalDecisions: [Decision]

    /// The file at the repository root, found from this source file's path.
    static func load(filePath: String = #filePath) throws -> HubTestVectors {
        var url = URL(fileURLWithPath: filePath)
        // Tests/CmuxDeviceHubTests/<file> → Packages/Shared/CmuxDeviceHub → repository root.
        for _ in 0 ..< 6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("schemas/device-hub/test-vectors.json"))
        return try JSONDecoder().decode(HubTestVectors.self, from: data)
    }
}

func hexBytes(_ hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
        index = next
    }
    return data
}

func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Suite struct HubTestVectorTests {
    let vectors: HubTestVectors

    init() throws {
        vectors = try HubTestVectors.load()
    }

    @Test func theVectorKeyIsTheListedSigningKey() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: hexBytes(vectors.key.privateKeyHex))
        #expect(key.publicKey.x963Representation.base64EncodedString() == vectors.key.signingKey)
    }

    @Test func requestSigningCanonicalStringsAndSignatures() throws {
        #expect(vectors.requestSigning.count == 3)
        for vector in vectors.requestSigning {
            let body = vector.body.isEmpty ? nil : Data(vector.body.utf8)
            #expect((body.map { HubJSON.sha256Hex($0) } ?? "") == vector.bodySha256)
            let canonical = DeviceRequestSigner.canonical(method: vector.method, pathAndQuery: vector.pathAndQuery,
                                                          timestamp: try #require(Int(vector.ts)), body: body)
            #expect(canonical == vector.canonical)
            let message = Data(canonical.utf8)
            #expect(DeviceIdentity.verify(signature: vector.sig, of: message, signingKey: vectors.key.signingKey))
            #expect(DeviceIdentity.verify(signature: vector.sigHighS, of: message, signingKey: vectors.key.signingKey))
            // The high-S form is the low-S one with s flipped, and back.
            let high = try #require(Data(base64Encoded: vector.sigHighS))
            #expect(DeviceIdentity.flippedS(high).map(hexString) == vector.lowSHex)
            #expect(!DeviceIdentity.verify(signature: vector.sig, of: Data((canonical + "x").utf8), signingKey: vectors.key.signingKey))
        }
    }

    @Test func canonicalJSONMatchesByteForByte() throws {
        #expect(vectors.canonicalJson.count == 2)
        for vector in vectors.canonicalJson {
            #expect(try vector.value.canonical() == vector.canonical)
            #expect(try vector.value.canonicalSHA256() == vector.sha256)
        }
    }

    @Test func theApprovalRequestsDigestIsRecomputed() throws {
        let request = vectors.approvalRequest.request
        #expect(try request.computedDigest() == request.digest)
        #expect(request.digest == "8b103ea20764ba906dc15f5fc3a90a99de23c979a7d53df845577a268c73e1d5")
        #expect(request.digestMatches)
        #expect(request.target == ComputerUseApprovalRequest.Target(bundleID: nil, executable: "/usr/bin/gedit", name: "Text Editor \"β\"\n/tmp ☃ \u{1}"))
        #expect(request.agent == "Claude" && request.workspace == "api-server" && request.tool == "click" && request.machine == "build-box-7")
        #expect(request.answerableUntil == Date(timeIntervalSince1970: 1_793_400_600))
        // Any changed field, a known one or one this build does not know, breaks the digest.
        var changed = request
        changed.fields["tool"] = .string("type")
        #expect(!changed.digestMatches)
        var extra = request
        extra.fields["future_field"] = .string("x")
        #expect(!extra.digestMatches)
    }

    @Test func decisionMessagesAndSignaturesVerify() throws {
        let digest = try #require(vectors.approvalRequest.request.digest)
        #expect(vectors.approvalDecisions.map(\.decision) == [.once, .session, .always, .deny])
        for vector in vectors.approvalDecisions {
            #expect(vector.decision.signatureMessage(digest: digest) == vector.message)
            #expect(DeviceIdentity.verifyApproval(signature: vector.sig, digest: digest, decision: vector.decision, signingKey: vectors.key.signingKey))
            #expect(DeviceIdentity.verifyApproval(signature: vector.sigHighS, digest: digest, decision: vector.decision, signingKey: vectors.key.signingKey))
            #expect(DeviceIdentity.flippedS(try #require(Data(base64Encoded: vector.sigHighS))).map(hexString) == vector.lowSHex)
            // A signature over one decision never stands for another.
            for other in ComputerUseDecision.allCases where other != vector.decision {
                #expect(!DeviceIdentity.verifyApproval(signature: vector.sig, digest: digest, decision: other, signingKey: vectors.key.signingKey))
            }
        }
    }

    @Test func thisDevicesDecisionSignatureVerifiesWithItsKey() throws {
        let identity = DeviceIdentity.software()
        let digest = try #require(vectors.approvalRequest.request.digest)
        let sig = try identity.signApproval(digest: digest, decision: .session)
        #expect(Data(base64Encoded: sig)?.count == 64)
        #expect(DeviceIdentity.verifyApproval(signature: sig, digest: digest, decision: .session, signingKey: identity.signingKey))
        #expect(!DeviceIdentity.verifyApproval(signature: sig, digest: digest, decision: .once, signingKey: identity.signingKey))
    }
}

@Suite struct CanonicalJSONTests {
    func decode(_ text: String) throws -> HubJSON { try JSONDecoder().decode(HubJSON.self, from: Data(text.utf8)) }

    @Test func fractionsAreRefused() throws {
        #expect(throws: HubJSON.CanonicalError.notAnInteger) { try decode(#"{"a":1.5}"#).canonical() }
    }

    @Test func booleansStayBooleansAndNumbersStayNumbers() throws {
        #expect(try decode(#"[true,1,0,false,null]"#).canonical() == "[true,1,0,false,null]")
    }

    @Test func slashAndNonASCIIAreWrittenAsThemselves() throws {
        #expect(try HubJSON.string("a/b é \u{7f}").canonical() == "\"a/b é \u{7f}\"")
        #expect(try HubJSON.string("\u{0}\u{1f}").canonical() == #""\u0000\u001f""#)
    }

    @Test func keysSortByCodePoint() throws {
        #expect(try decode(#"{"b":1,"B":2,"a_b":3,"aa":4}"#).canonical() == #"{"B":2,"a_b":3,"aa":4,"b":1}"#)
    }
}

/// An approval for the vector request, as the hub would send it.
func vectorApproval(id: String = "0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60", asker: String = "a5b2c3d4-0000-4000-8000-000000000007",
                    state: String = "pending", allowAlways: Bool = false) throws -> String {
    let vectors = try HubTestVectors.load()
    let request = String(decoding: try JSONEncoder().encode(vectors.approvalRequest.request), as: UTF8.self)
    return #"{"id":"\#(id)","deviceId":"\#(asker)","deviceName":"build-box-7","request":\#(request),"allowAlways":\#(allowAlways),"state":"\#(state)","createdAt":1793400000000,"answerableUntil":1793400600000}"#
}

@Suite struct ComputerUseApprovalModelTests {
    let phone = "6f1c2a4e-0d3b-4c5a-9e7f-112233445566"
    let before = Date(timeIntervalSince1970: 1_793_400_100)

    func approval(_ json: String) throws -> ComputerUseApproval {
        try JSONDecoder().decode(ComputerUseApproval.self, from: Data(json.utf8))
    }

    @Test func aPendingApprovalFromAnotherMachineIsAnswerable() throws {
        let value = try approval(try vectorApproval())
        #expect(value.deviceName == "build-box-7" && value.state == .pending && !value.allowAlways)
        #expect(value.refusal(thisDeviceID: phone, now: before) == nil)
        // A round trip keeps every request field, so the digest still holds.
        let again = try JSONDecoder().decode(ComputerUseApproval.self, from: try JSONEncoder().encode(value))
        #expect(again == value && again.request.digestMatches)
    }

    @Test func refusals() throws {
        #expect(try approval(try vectorApproval(asker: phone.uppercased())).refusal(thisDeviceID: phone, now: before) == .ownRequest)
        #expect(try approval(try vectorApproval(state: "decided")).refusal(thisDeviceID: phone, now: before) == .notPending)
        #expect(try approval(try vectorApproval(state: "something-new")).refusal(thisDeviceID: phone, now: before) == .notPending)
        #expect(try approval(try vectorApproval()).refusal(thisDeviceID: phone, now: Date(timeIntervalSince1970: 1_793_400_600)) == .expired)
        var tampered = try approval(try vectorApproval())
        tampered.request.fields["target"] = .object(["bundle_id": .string("com.apple.Terminal"), "executable": .null, "name": .string("Safari")])
        #expect(tampered.refusal(thisDeviceID: phone, now: before) == .digestMismatch)
    }

    @Test func aRequestPushHasNoStateAndIsPending() throws {
        let text = try vectorApproval().replacingOccurrences(of: #","state":"pending""#, with: "")
        #expect(try approval(text).state == .pending)
    }
}

@Suite struct ApprovalPushTests {
    @Test func approvalPushesDecode() throws {
        let request = try vectorApproval(allowAlways: true)
        guard case let .approvalRequest(approval)? = DeviceHubPush(text: #"{"type":"approval.request","approval":\#(request)}"#) else {
            Issue.record("approval.request did not decode")
            return
        }
        #expect(approval.allowAlways && approval.request.digestMatches)

        let decided = DeviceHubPush(text: #"{"type":"approval.decided","id":"a1","decision":"session","digest":"d","deciderId":"p","sig":"s"}"#)
        #expect(decided == .approvalDecided(ComputerUseApprovalDecided(id: "a1", decision: .session, digest: "d", deciderId: "p", sig: "s")))
        #expect(DeviceHubPush(text: #"{"type":"approval.closed","id":"a1","state":"expired","decision":null}"#)
            == .approvalClosed(id: "a1", state: .expired, decision: nil))
        #expect(DeviceHubPush(text: #"{"type":"approval.closed","id":"a1","state":"decided","decision":"deny"}"#)
            == .approvalClosed(id: "a1", state: .decided, decision: .deny))
        // Malformed approval pushes are dropped, not misread.
        #expect(DeviceHubPush(text: #"{"type":"approval.closed"}"#) == nil)
        #expect(DeviceHubPush(text: #"{"type":"approval.decided","id":"a1","decision":"forever","digest":"d","deciderId":"p","sig":"s"}"#) == nil)
    }

    @Test func newErrorCodesRoundTrip() {
        for raw in ["digest_mismatch", "approval_exists", "self_approval", "not_approver", "not_asker", "approval_not_pending",
                    "approval_expired", "always_not_allowed", "bad_decision_signature", "not_self"] {
            let code = DeviceHubError.Code(raw)
            #expect(code.rawValue == raw)
            #expect(code != .other(raw))
        }
    }
}

@Suite struct ComputerUseApprovalClientTests {
    @Test func approvalEndpointsHaveTheirMethodPathAndBody() async throws {
        let identity = DeviceIdentity.software()
        let approval = try vectorApproval(id: "ap1")
        let hub = StubHub.routes([
            "GET /v1/approvals": (200, #"{"approvals":[\#(approval)]}"#),
            "GET /v1/approvals/ap1": (200, #"{"approval":\#(approval)}"#),
            "POST /v1/approvals/ap1/decision": (200, #"{"approval":\#(approval.replacingOccurrences(of: #""state":"pending""#, with: #""state":"decided""#))}"#),
            "PUT /v1/devices/\(identity.id)/push": (200, #"{"push":{"registered":true,"configured":false}}"#),
        ])
        let client = makeClient(hub, identity: identity)
        #expect(try await client.pendingApprovals().map(\.id) == ["ap1"])
        let fetched = try await client.approval(id: "ap1")
        let digest = try fetched.request.computedDigest()
        let decided = try await client.decide(id: "ap1", decision: .once, digest: digest)
        #expect(decided.state == .decided)
        let push = try await client.registerPush(token: "ab12", topic: "dev.cmux.mobile", environment: .development)
        #expect(push == DeviceHubPushRegistration(registered: true, configured: false))
        _ = try await client.registerPush(token: nil, topic: "dev.cmux.mobile", environment: .production)

        let calls = hub.requests.filter { $0.url.path != "/v1/auth/stack" }
        #expect(calls.map { "\($0.method) \($0.pathAndQuery)" } == [
            "GET /v1/approvals", "GET /v1/approvals/ap1", "POST /v1/approvals/ap1/decision",
            "PUT /v1/devices/\(identity.id)/push", "PUT /v1/devices/\(identity.id)/push",
        ])
        for call in calls {
            #expect(call.header("X-Device-Id") == identity.id)
            let canonical = DeviceRequestSigner.canonical(method: call.method, pathAndQuery: call.pathAndQuery, timestamp: 1_800_000_000, body: call.body)
            #expect(DeviceIdentity.verify(signature: call.header("X-Device-Sig") ?? "", of: Data(canonical.utf8), signingKey: identity.signingKey))
        }
        let decision = try #require(calls[2].jsonBody)
        #expect(decision["decision"] as? String == "once")
        #expect(decision["digest"] as? String == digest)
        let sig = try #require(decision["sig"] as? String)
        #expect(DeviceIdentity.verifyApproval(signature: sig, digest: digest, decision: .once, signingKey: identity.signingKey))
        let register = try #require(calls[3].jsonBody)
        #expect(register["token"] as? String == "ab12" && register["topic"] as? String == "dev.cmux.mobile" && register["environment"] as? String == "development")
        let forget = try #require(calls[4].jsonBody)
        #expect(forget.keys.contains("token") && forget["token"] is NSNull && forget["environment"] as? String == "production")
    }

    @Test func approvalRefusalsCarryTheirCodes() async throws {
        let hub = StubHub.routes(["POST /v1/approvals/ap1/decision": (409, #"{"error":{"code":"approval_not_pending","message":"decided"}}"#)])
        await #expect(throws: DeviceHubError.server(status: 409, code: .approvalNotPending, message: "decided")) {
            _ = try await makeClient(hub).decide(id: "ap1", decision: .deny, digest: "d")
        }
    }
}

@MainActor
@Suite struct DeviceHubApprovalListTests {
    func hub(following: Bool) -> DeviceHub {
        let stub = StubHub.routes([:])
        let hub = DeviceHub(client: makeClient(stub), secrets: MemoryRelaySecretStore(), deviceName: "Phone", platform: .ios, now: fixedNow)
        hub.followsApprovals = following
        return hub
    }

    @Test func requestsAddAndClosesDrop() async throws {
        let hub = hub(following: true)
        var seen: [DeviceHubPush] = []
        hub.onApprovalPush = { seen.append($0) }
        let approval = try JSONDecoder().decode(ComputerUseApproval.self, from: Data(try vectorApproval(id: "ap1").utf8))
        await hub.handle(.approvalRequest(approval))
        await hub.handle(.approvalRequest(approval))
        #expect(hub.approvals.map(\.id) == ["ap1"])
        await hub.handle(.approvalClosed(id: "ap1", state: .expired, decision: nil))
        #expect(hub.approvals.isEmpty && seen.count == 3)
    }

    @Test func aDeviceThatDoesNotFollowApprovalsKeepsNone() async throws {
        let hub = hub(following: false)
        let approval = try JSONDecoder().decode(ComputerUseApproval.self, from: Data(try vectorApproval(id: "ap1").utf8))
        await hub.handle(.approvalRequest(approval))
        #expect(hub.approvals.isEmpty)
    }
}
