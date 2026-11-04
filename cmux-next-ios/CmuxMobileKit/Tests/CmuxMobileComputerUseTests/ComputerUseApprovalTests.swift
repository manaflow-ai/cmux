import CmuxDeviceHub
@testable import CmuxMobileComputerUse
import CmuxMobileNotifications
import CryptoKit
import Foundation
import Testing

// MARK: Fixtures

/// The shared vectors' approval request (schemas/device-hub/test-vectors.json).
enum Fixture {
    static func vectorsData(filePath: String = #filePath) throws -> Data {
        var url = URL(fileURLWithPath: filePath)
        // Tests/CmuxMobileComputerUseTests/<file> → CmuxMobileKit → cmux-next-ios → repository root.
        for _ in 0 ..< 5 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent("schemas/device-hub/test-vectors.json"))
    }

    /// The request object's JSON text, digest included.
    static func requestJSON() throws -> String {
        let object = try #require(try JSONSerialization.jsonObject(with: vectorsData()) as? [String: Any])
        let approval = try #require(object["approvalRequest"] as? [String: Any])
        let request = try #require(approval["request"])
        return String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    }

    static func request() throws -> ComputerUseApprovalRequest {
        try JSONDecoder().decode(ComputerUseApprovalRequest.self, from: Data(requestJSON().utf8))
    }

    static let asker = "a5b2c3d4-0000-4000-8000-000000000007"
    static let phone = "6f1c2a4e-0d3b-4c5a-9e7f-112233445566"
    /// Before the vector request's deadline (1793400600 s).
    static let before = Date(timeIntervalSince1970: 1_793_400_100)
    static let after = Date(timeIntervalSince1970: 1_793_400_601)

    static func approvalJSON(id: String = "ap1", asker: String = Fixture.asker, state: String = "pending", allowAlways: Bool = false) throws -> String {
        #"{"id":"\#(id)","deviceId":"\#(asker)","deviceName":"build-box-7","request":\#(try requestJSON()),"allowAlways":\#(allowAlways),"state":"\#(state)","answerableUntil":1793400600000}"#
    }

    static func approval(id: String = "ap1", asker: String = Fixture.asker, state: String = "pending", allowAlways: Bool = false) throws -> ComputerUseApproval {
        try JSONDecoder().decode(ComputerUseApproval.self, from: Data(approvalJSON(id: id, asker: asker, state: state, allowAlways: allowAlways).utf8))
    }

    /// A Mac's `computer_use` push payload carrying the vector request.
    static func macPayload(always: Bool = false, tamper: Bool = false) throws -> PushPayload {
        var request = try JSONDecoder().decode(PushJSON.self, from: Data(requestJSON().utf8))
        if tamper, case var .object(object) = request {
            object["tool"] = .string("type")
            request = .object(object)
        }
        return PushPayload(mac: "mac-1", macName: "Studio", kind: .computerUse, eventId: "cu-8b103ea20764ba906dc15f5fc3a90a99",
                           agent: "Claude", workspace: "api-server", title: "Text Editor",
                           computerUse: PushComputerUse(request: request, always: always))
    }
}

/// Software keys for a test device (the app's are in the Secure Enclave).
struct TestKeys: DeviceKeyMaterial {
    let signing = P256.Signing.PrivateKey()
    let agreement = P256.KeyAgreement.PrivateKey()
    var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
    func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
    func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
                                           encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext)
    }
}

// MARK: The review (sheet model)

@Suite struct ComputerUseApprovalReviewTests {
    @Test func aHubQuestionShowsTheFetchedRequest() throws {
        let review = try ComputerUseApprovalReview(approval: Fixture.approval(), thisDeviceID: Fixture.phone, now: Fixture.before)
        #expect(review.source == .hub(approvalID: "ap1") && review.id == "ap1")
        #expect(review.machineName == "build-box-7" && review.agent == "Claude" && review.workspace == "api-server" && review.tool == "click")
        #expect(review.appName == "Text Editor \"β\"\n/tmp ☃ \u{1}" && review.appIdentifier == "/usr/bin/gedit")
        #expect(review.digest == "8b103ea20764ba906dc15f5fc3a90a99de23c979a7d53df845577a268c73e1d5")
    }

    @Test func alwaysIsOfferedOnlyWhenTheMachineAllowsIt() throws {
        let plain = try ComputerUseApprovalReview(approval: Fixture.approval(allowAlways: false), thisDeviceID: Fixture.phone, now: Fixture.before)
        #expect(plain.choices == [.allowOnce, .allowSession, .deny] && !plain.offers(.alwaysAllow))
        let always = try ComputerUseApprovalReview(approval: Fixture.approval(allowAlways: true), thisDeviceID: Fixture.phone, now: Fixture.before)
        #expect(always.choices == [.allowOnce, .allowSession, .alwaysAllow, .deny])
        let mac = try ComputerUseApprovalReview(payload: Fixture.macPayload(always: false), now: Fixture.before)
        #expect(!mac.offers(.alwaysAllow))
        #expect(try ComputerUseApprovalReview(payload: Fixture.macPayload(always: true), now: Fixture.before).offers(.alwaysAllow))
    }

    @Test func refusesAMismatchedDigest() throws {
        var approval = try Fixture.approval()
        approval.request.fields["target"] = .object(["bundle_id": .string("com.apple.Terminal"), "executable": .null, "name": .string("Text Editor")])
        #expect(throws: ComputerUseApproval.Refusal.digestMismatch) {
            try ComputerUseApprovalReview(approval: approval, thisDeviceID: Fixture.phone, now: Fixture.before)
        }
        #expect(throws: ComputerUseApproval.Refusal.digestMismatch) {
            try ComputerUseApprovalReview(payload: Fixture.macPayload(tamper: true), now: Fixture.before)
        }
    }

    @Test func refusesExpiredClosedAndOwnQuestions() throws {
        #expect(throws: ComputerUseApproval.Refusal.expired) {
            try ComputerUseApprovalReview(approval: Fixture.approval(), thisDeviceID: Fixture.phone, now: Fixture.after)
        }
        #expect(throws: ComputerUseApproval.Refusal.expired) {
            try ComputerUseApprovalReview(payload: Fixture.macPayload(), now: Fixture.after)
        }
        #expect(throws: ComputerUseApproval.Refusal.notPending) {
            try ComputerUseApprovalReview(approval: Fixture.approval(state: "decided"), thisDeviceID: Fixture.phone, now: Fixture.before)
        }
        #expect(throws: ComputerUseApproval.Refusal.ownRequest) {
            try ComputerUseApprovalReview(approval: Fixture.approval(asker: Fixture.phone), thisDeviceID: Fixture.phone, now: Fixture.before)
        }
    }

    @Test func choicesMapToDecisions() {
        #expect(ComputerUseChoice.allowOnce.decision == .once)
        #expect(ComputerUseChoice.allowSession.decision == .session)
        #expect(ComputerUseChoice.alwaysAllow.decision == .always)
        #expect(ComputerUseChoice.deny.decision == .deny)
        #expect(ComputerUseChoice.allCases.filter(\.needsUserPresence) == [.allowOnce, .allowSession, .alwaysAllow])
        #expect(ComputerUseChoice(.allowOnce) == .allowOnce && ComputerUseChoice(.allowSession) == .allowSession)
        #expect(ComputerUseChoice(.allowAlways) == .alwaysAllow && ComputerUseChoice(.deny) == .deny)
    }

    @Test func aMacQuestionNamesTheMac() throws {
        let review = try ComputerUseApprovalReview(payload: Fixture.macPayload(), now: Fixture.before)
        #expect(review.source == .mac(id: "mac-1", name: "Studio") && review.machineName == "Studio")
        #expect(review.id == "mac:mac-1:\(review.digest)")
    }
}

// MARK: The coordinator

/// A hub behind URLProtocol for these tests.
final class ApprovalHubStub: URLProtocol, @unchecked Sendable {
    // nonisolated(unsafe): set once per test before any request, read by the loading thread.
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let (status, text) = Self.lock.withLock { () -> (Int, String) in
            if let body { Self.bodies[key] = body }
            if url.path == "/v1/auth/stack" { return (200, #"{"session":"s","userId":"u","expiresAt":4102444800000}"#) }
            return Self.routes[key] ?? (404, #"{"error":{"code":"not_found","message":"no route"}}"#)
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func client(identity: DeviceIdentity) -> DeviceHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApprovalHubStub.self]
        return DeviceHubClient(baseURL: URL(string: "https://hub.test")!, identity: identity, tokens: DeviceHubAccountToken { "t" },
                               session: URLSession(configuration: configuration), now: { Date() })
    }
}

@MainActor
@Suite(.serialized) struct ComputerUseApprovalsTests {
    let identity = DeviceIdentity(deviceID: UUID(uuidString: Fixture.phone)!, keys: TestKeys())

    func approvals(presence: @escaping @MainActor (String) async throws -> Void = { _ in },
                   answerMac: @escaping @MainActor (ComputerUseMacAnswer) async throws -> Void = { _ in }) -> ComputerUseApprovals {
        let client = ApprovalHubStub.client(identity: identity)
        return ComputerUseApprovals(environment: ComputerUseApprovals.Environment(
            hubURL: URL(string: "https://hub.test")!, client: { client }, answerMac: answerMac, userPresence: presence,
            isInteractive: { true }, pushTopic: "dev.cmux.mobile", now: { Fixture.before }))
    }

    @Test func aPushFromAnotherHubIsIgnored() async throws {
        ApprovalHubStub.routes = ["GET /v1/approvals/ap1": (200, #"{"approval":\#(try Fixture.approvalJSON())}"#)]
        let model = approvals()
        let notice = ComputerUseApprovalNotice(approvalID: "ap1", deviceID: Fixture.asker, hub: URL(string: "https://evil.example")!)
        await model.handle(notice, action: nil, requireFaceID: false)
        #expect(model.sheet == nil)
    }

    @Test func aTapShowsTheFetchedQuestion() async throws {
        ApprovalHubStub.routes = ["GET /v1/approvals/ap1": (200, #"{"approval":\#(try Fixture.approvalJSON())}"#)]
        let model = approvals()
        await model.handle(ComputerUseApprovalNotice(approvalID: "ap1", deviceID: Fixture.asker, hub: URL(string: "https://hub.test")!),
                           action: nil, requireFaceID: false)
        #expect(model.sheet?.phase == .ready && model.sheet?.review?.appName.hasPrefix("Text Editor") == true)
    }

    @Test func anAllowAsksForFaceIDThenSignsTheRecomputedDigest() async throws {
        let approval = try Fixture.approvalJSON()
        ApprovalHubStub.routes = [
            "GET /v1/approvals/ap1": (200, #"{"approval":\#(approval)}"#),
            "POST /v1/approvals/ap1/decision": (200, #"{"approval":\#(approval.replacingOccurrences(of: #""state":"pending""#, with: #""state":"decided""#))}"#),
        ]
        var reasons: [String] = []
        let model = approvals(presence: { reasons.append($0) })
        await model.open("ap1")
        let review = try #require(model.sheet?.review)
        await model.decide(review, choice: .allowSession)
        #expect(model.sheet?.phase == .decided(.session))
        #expect(reasons.count == 1 && reasons[0].contains("Claude"))
        let body = try #require(ApprovalHubStub.lock.withLock { ApprovalHubStub.bodies["POST /v1/approvals/ap1/decision"] })
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(sent["decision"] == "session" && sent["digest"] == review.digest)
        #expect(DeviceIdentity.verifyApproval(signature: sent["sig"] ?? "", digest: review.digest, decision: .session, signingKey: identity.signingKey))
    }

    @Test func cancelledFaceIDSignsNothing() async throws {
        ApprovalHubStub.routes = ["GET /v1/approvals/ap1": (200, #"{"approval":\#(try Fixture.approvalJSON())}"#)]
        ApprovalHubStub.lock.withLock { ApprovalHubStub.bodies = [:] }
        struct Cancelled: Error {}
        let model = approvals(presence: { _ in throw Cancelled() })
        await model.open("ap1")
        await model.decide(try #require(model.sheet?.review), choice: .allowOnce)
        #expect(model.sheet?.phase == .ready)
        #expect(ApprovalHubStub.lock.withLock { ApprovalHubStub.bodies["POST /v1/approvals/ap1/decision"] } == nil)
    }

    @Test func aClosedQuestionLeavesTheSheet() async throws {
        ApprovalHubStub.routes = ["GET /v1/approvals/ap1": (200, #"{"approval":\#(try Fixture.approvalJSON())}"#)]
        let model = approvals()
        await model.open("ap1")
        model.route(.approvalClosed(id: "ap1", state: .decided, decision: .deny))
        guard case .failed? = model.sheet?.phase else {
            Issue.record("the sheet still offers answers")
            return
        }
    }

    @Test func aMacQuestionIsAnsweredThroughTheMac() async throws {
        var sent: [ComputerUseMacAnswer] = []
        let model = approvals(answerMac: { sent.append($0) })
        let payload = try Fixture.macPayload()
        // A lock-screen Deny goes without opening the app.
        await model.handle(macPayload: payload, action: .deny, actionable: true, requireFaceID: false)
        #expect(sent.map(\.decision) == [.deny] && model.sheet == nil)
        // An Allow button opens the sheet and answers once Face ID can show.
        await model.handle(macPayload: payload, action: .allowOnce, actionable: true, requireFaceID: false)
        #expect(model.sheet?.phase == .decided(.once))
        #expect(sent.map(\.decision) == [.deny, .once])
        #expect(sent.last?.digest == "8b103ea20764ba906dc15f5fc3a90a99de23c979a7d53df845577a268c73e1d5" && sent.last?.macID == "mac-1")
    }

    @Test func anUntrustedMacPushAnswersNothing() async throws {
        var sent: [ComputerUseMacAnswer] = []
        let model = approvals(answerMac: { sent.append($0) })
        await model.handle(macPayload: try Fixture.macPayload(), action: .allowOnce, actionable: false, requireFaceID: false)
        #expect(sent.isEmpty)
        guard case .failed? = model.sheet?.phase else {
            Issue.record("an untrusted push offered answers")
            return
        }
    }
}
