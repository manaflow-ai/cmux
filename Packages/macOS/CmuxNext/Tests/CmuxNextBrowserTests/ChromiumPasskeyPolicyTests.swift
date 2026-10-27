import CryptoKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The WEBAUTHN relay's data rules (p01-process-067, plans/cmux-next/passkeys.md 3.9.3): the fork's request JSON,
/// the checks cmux makes before it signs for a page, Chromium's related origins rules and the reply JSON.
@Suite struct ChromiumPasskeyPolicyTests {
    static let suffixes = PublicSuffixList(listText: "com\nio\nco.uk\n")
    let policy = ChromiumPasskeyPolicy(publicSuffixes: Self.suffixes)
    let page = ChromiumPasskeyPage(origin: "https://login.example.com", isVisible: true, isAgentDriven: false)

    static func clientData(type: String = "webauthn.get", origin: String = "https://login.example.com",
                           crossOrigin: String = #","crossOrigin":false"#, extra: String = "") -> String {
        #"{"type":"\#(type)","challenge":"AQID","origin":"\#(origin)"\#(crossOrigin)\#(extra)}"#
    }

    static func get(rp: String = "example.com", clientData: String = clientData(), hash: Data? = nil,
                    allow: [String] = ["CQ"], requestPermission: Bool = false) -> String {
        let hash = hash ?? Data(SHA256.hash(data: Data(clientData.utf8)))
        let object: [String: Any] = ["rp_id": rp, "client_data_json": clientData, "client_data_hash": ChromiumPlatformPasskeyRequest.text(hash),
                                     "allow_credentials": allow, "show_hybrid_transport": false, "user_verification": "required",
                                     "request_permission": requestPermission]
        return json(object)
    }

    static func create(rp: String = "example.com", algorithms: [Int] = [-7, -257], largeBlob: String? = nil,
                       userID: String = "dXNlcg") -> String {
        let data = clientData(type: "webauthn.create")
        var object: [String: Any] = ["rp_id": rp, "client_data_json": data,
                                     "client_data_hash": ChromiumPlatformPasskeyRequest.text(Data(SHA256.hash(data: Data(data.utf8)))),
                                     "user": ["id": userID, "name": "person@example.com", "display_name": "Person"],
                                     "algorithms": algorithms, "exclude_credentials": [["id": "CQ", "transports": ["internal"]]],
                                     "resident_key_required": true, "user_verification": "preferred", "attestation": "none",
                                     "request_permission": true]
        if let largeBlob { object["large_blob"] = largeBlob }
        return json(object)
    }

    /// The fixture as JSON text; JSONSerialization takes every dictionary these fixtures build.
    static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func verdict(_ json: String, operation: ChromiumPlatformPasskeyOperation = .get,
                 page: ChromiumPasskeyPage?) -> Result<ChromiumPasskeyPolicy.Verdict, ChromiumPasskeyRefusal>? {
        guard let request = ChromiumPlatformPasskeyRequest.parse(json, operation: operation) else { return nil }
        return policy.check(request, clientData: ChromiumClientData(request.clientDataJSON), page: page)
    }

    // MARK: The request JSON

    @Test func aGetKeepsWhatTheSystemRequestNeeds() throws {
        let request = try #require(ChromiumPlatformPasskeyRequest.parse(Self.get(), operation: .get))
        #expect(request.rpID == "example.com")
        #expect(request.allowCredentials == [Data([9])])
        #expect(request.userVerification == "required")
        #expect(request.showsHybridTransport == false)
        #expect(request.clientDataJSON == Data(Self.clientData().utf8))
    }

    @Test func aCreateKeepsTheUserAndExcludedCredentials() throws {
        let request = try #require(ChromiumPlatformPasskeyRequest.parse(Self.create(), operation: .create))
        #expect(request.user == .init(id: Data("user".utf8), name: "person@example.com", displayName: "Person"))
        #expect(request.excludeCredentials == [Data([9])])
        #expect(request.algorithms == [-7, -257])
        #expect(request.requestPermission)
    }

    @Test func malformedRequestsAreNoRequest() {
        #expect(ChromiumPlatformPasskeyRequest.parse("[]", operation: .get) == nil)
        #expect(ChromiumPlatformPasskeyRequest.parse(Self.get(rp: ""), operation: .get) == nil)
        #expect(ChromiumPlatformPasskeyRequest.parse(Self.get(allow: ["not base64url!"]), operation: .get) == nil)
        #expect(ChromiumPlatformPasskeyRequest.parse(Self.create(userID: "a+b/"), operation: .create) == nil)
        #expect(ChromiumPlatformPasskeyRequest.parse(#"{"rp_id":"example.com"}"#, operation: .get) == nil)
        #expect(ChromiumPlatformPasskeyRequest.parse(#"{"rp_id":"Example.COM"}"#, operation: .list)?.rpID == "example.com")
    }

    @Test func base64URLRoundTrips() {
        let bytes = Data((0...255).map(UInt8.init))
        #expect(ChromiumPlatformPasskeyRequest.bytes(ChromiumPlatformPasskeyRequest.text(bytes)) == bytes)
        #expect(!ChromiumPlatformPasskeyRequest.text(bytes).contains { "+/=".contains($0) })
    }

    // MARK: The checks (3.9.3)

    @Test func aVisiblePageOfTheOriginMaySignForItsSiteAndItsHost() {
        #expect(verdict(Self.get(), page: page) == .success(.allowed))
        #expect(verdict(Self.get(rp: "login.example.com"), page: page) == .success(.allowed))
    }

    @Test func aPageCmuxDoesNotShowOrAnAgentDrivesIsRefused() {
        #expect(verdict(Self.get(), page: nil) == .failure(.unknownBrowser))
        #expect(verdict(Self.get(), page: .init(origin: page.origin, isVisible: false, isAgentDriven: false)) == .failure(.notVisible))
        #expect(verdict(Self.get(), page: .init(origin: page.origin, isVisible: true, isAgentDriven: true)) == .failure(.agentLease))
        #expect(verdict(Self.get(), page: .init(origin: nil, isVisible: true, isAgentDriven: false)) == .failure(.origin))
        #expect(verdict(Self.get(), page: .init(origin: "http://login.example.com", isVisible: true, isAgentDriven: false)) == .failure(.origin))
    }

    @Test func clientDataMustBeThePagesAndMatchItsHash() {
        #expect(verdict(Self.get(hash: Data(repeating: 0, count: 32)), page: page) == .failure(.clientDataHash))
        #expect(verdict(Self.get(clientData: Self.clientData(type: "webauthn.create")), page: page) == .failure(.clientDataType))
        #expect(verdict(Self.get(clientData: Self.clientData(origin: "https://evil.com")), page: page) == .failure(.origin))
        let otherKey = Self.clientData(extra: #","other_keys_can_be_added_here":"do not compare clientDataJSON against a template""#)
        #expect(verdict(Self.get(clientData: otherKey), page: page) == .failure(.clientDataNotReproducible))
    }

    @Test func aCrossOriginFrameNeedsThePageAsItsTopOrigin() {
        let framed = Self.clientData(origin: "https://pay.example.com", crossOrigin: #","crossOrigin":true,"topOrigin":"https://login.example.com""#)
        #expect(verdict(Self.get(clientData: framed), page: page) == .success(.allowed))
        let elsewhere = Self.clientData(origin: "https://pay.example.com", crossOrigin: #","crossOrigin":true,"topOrigin":"https://evil.com""#)
        #expect(verdict(Self.get(clientData: elsewhere), page: page) == .failure(.origin))
        let notFramed = Self.clientData(origin: "https://pay.example.com")
        #expect(verdict(Self.get(clientData: notFramed), page: page) == .failure(.origin))
    }

    @Test func anRPIDOutsideTheOriginNeedsItsRelatedOrigins() {
        #expect(verdict(Self.get(rp: "other.com"), page: page) == .success(.needsRelatedOrigins(callerOrigin: "https://login.example.com")))
        // A public suffix is never registrable, so only its related origins list could allow it.
        #expect(verdict(Self.get(rp: "com"), page: page) == .success(.needsRelatedOrigins(callerOrigin: "https://login.example.com")))
        #expect(verdict(Self.get(rp: "ample.com"), page: page) == .success(.needsRelatedOrigins(callerOrigin: "https://login.example.com")))
    }

    @Test func iCloudKeychainCreatesOnlyES256AndNoRequiredLargeBlob() {
        #expect(verdict(Self.create(), operation: .create, page: page) == .success(.allowed))
        #expect(verdict(Self.create(algorithms: [-257]), operation: .create, page: page) == .failure(.unsupported))
        #expect(verdict(Self.create(largeBlob: "required"), operation: .create, page: page) == .failure(.unsupported))
        #expect(verdict(Self.create(largeBlob: "preferred"), operation: .create, page: page) == .success(.allowed))
    }

    @Test func aListNeedsOnlyTheOriginNotTheView() throws {
        let request = try #require(ChromiumPlatformPasskeyRequest.parse(#"{"rp_id":"example.com"}"#, operation: .list))
        let hidden = ChromiumPasskeyPage(origin: page.origin, isVisible: false, isAgentDriven: false)
        #expect(policy.check(request, clientData: nil, page: hidden) == .success(.allowed))
        #expect(policy.check(request, clientData: nil, page: .init(origin: page.origin, isVisible: true, isAgentDriven: true)) == .failure(.agentLease))
    }

    @Test func originsSerializeAsChromiumDoes() {
        #expect(ChromiumPasskeyPolicy.origin(of: URL(string: "https://Login.Example.com:443/a?b")!) == "https://login.example.com")
        #expect(ChromiumPasskeyPolicy.origin(of: URL(string: "https://example.com:8443/")!) == "https://example.com:8443")
        #expect(ChromiumPasskeyPolicy.origin(of: URL(string: "http://localhost:3000/")!) == "http://localhost:3000")
        #expect(ChromiumPasskeyPolicy.origin(of: URL(string: "about:blank")!) == nil)
        #expect(ChromiumPasskeyPolicy.isSecure("http://localhost:3000"))
        #expect(!ChromiumPasskeyPolicy.isSecure("http://example.com"))
    }

    // MARK: Related origins

    @Test func relatedOriginsFollowChromiumsLabelLimit() {
        let related = ChromiumRelatedOrigins(publicSuffixes: Self.suffixes)
        let listed = Data(#"{"origins":["https://a.com","https://b.com","https://c.com","https://d.com","https://e.com","https://f.com","https://a.co.uk"]}"#.utf8)
        #expect(related.lists("https://e.com", in: listed))
        // The sixth label is past Chromium's five; an origin of a label already seen still counts.
        #expect(!related.lists("https://f.com", in: listed))
        #expect(related.lists("https://a.co.uk", in: listed))
        #expect(!related.lists("https://a.com", in: Data(#"{"origin":["https://a.com"]}"#.utf8)))
    }

    // MARK: The reply JSON

    @Test func aReplyCarriesTheResultOnlyForChromiumsClientData() throws {
        let chromium = Data(Self.clientData().utf8)
        let assertion = ChromiumPasskeyCeremonyResult.assertion(credentialID: Data([9]), authenticatorData: Data([1]), signature: Data([2]),
                                                                userHandle: nil, clientDataJSON: chromium)
        let json = try #require(ChromiumPasskeyReply.json(for: assertion, chromiumClientData: chromium, permission: .authorized))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["signature"] as? String == "Ag")
        #expect(object["credential_id"] as? String == "CQ")
        #expect(object["user_handle"] == nil) // K11: no user handle stays none
        #expect(object["permission"] as? Int == 2)
        let other = ChromiumPasskeyCeremonyResult.assertion(credentialID: Data([9]), authenticatorData: Data([1]), signature: Data([2]),
                                                            userHandle: nil, clientDataJSON: Data("{}".utf8))
        #expect(ChromiumPasskeyReply.json(for: other, chromiumClientData: chromium, permission: .authorized) == nil)
        let noAttestation = ChromiumPasskeyCeremonyResult.registration(credentialID: Data([9]), attestationObject: nil, clientDataJSON: chromium)
        #expect(ChromiumPasskeyReply.json(for: noAttestation, chromiumClientData: chromium, permission: .authorized) == nil)
    }

    @Test func anErrorReplyNamesTheSystemsError() throws {
        let failed = ChromiumPasskeyCeremonyResult.failure(domain: "com.apple.AuthenticationServices.AuthorizationError", code: 1001,
                                                           description: "No credentials available for login.")
        let json = try #require(ChromiumPasskeyReply.json(for: failed, chromiumClientData: Data(), permission: .denied))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == 1001)
        #expect(object["permission"] as? Int == 1)
    }

    // MARK: The events

    @Test func theEventsDecodeAndNeverPrintTheRequest() {
        let secret = Self.get()
        let event = CEFShimEvent(kind: 62, browser: 7, request: 1, a: 41, b: 0, s1: secret, s2: "")
        #expect(event == .webAuthnPlatform(.request(browser: 7, token: 41, operation: 1, json: secret)))
        #expect(CEFShimEvent(kind: 63, browser: 0, request: 0, a: 41, b: 0, s1: "", s2: "") == .webAuthnPlatform(.cancel(token: 41)))
        #expect(event.browserID == nil)
        let printed = String(describing: event) + String(reflecting: event) + "\(event)"
        #expect(!printed.contains("AQID"))
        #expect(!printed.contains("client_data"))
    }
}
