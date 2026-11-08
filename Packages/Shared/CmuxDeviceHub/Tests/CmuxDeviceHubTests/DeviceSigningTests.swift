import CryptoKit
@testable import CmuxDeviceHub
import Foundation
import Testing

@Suite struct DeviceSigningTests {
    @Test func canonicalStringIsMethodPathTimestampAndBodyHash() {
        let body = Data(#"{"scope":"view"}"#.utf8)
        let canonical = DeviceRequestSigner.canonical(method: "put", pathAndQuery: "/v1/permissions/h/v", timestamp: 1_800_000_000, body: body)
        #expect(canonical == "PUT\n/v1/permissions/h/v\n1800000000\n1994f92bb196794929460c76aba830d42b5158bf62cd96a3561f4256fb7bcc3c")
    }

    @Test func canonicalBodyLineIsEmptyWithoutABody() {
        #expect(DeviceRequestSigner.canonical(method: "GET", pathAndQuery: "/v1/audit?limit=5", timestamp: 7, body: nil)
            == "GET\n/v1/audit?limit=5\n7\n")
        #expect(DeviceRequestSigner.canonical(method: "DELETE", pathAndQuery: "/v1/relays/r", timestamp: 7, body: Data())
            == "DELETE\n/v1/relays/r\n7\n")
    }

    @Test func pathAndQueryKeepsPercentEncodingAndQuery() {
        let url = URL(string: "wss://hub.example/v1/sessions/s%201/ws?ticket=a.b.c")!
        #expect(DeviceRequestSigner.pathAndQuery(of: url) == "/v1/sessions/s%201/ws?ticket=a.b.c")
        #expect(DeviceRequestSigner.pathAndQuery(of: URL(string: "https://hub.example")!) == "/")
    }

    @Test func headersVerifyWithTheRegisteredKey() throws {
        let identity = DeviceIdentity.software()
        let signer = DeviceRequestSigner(identity: identity, now: fixedNow)
        let body = Data(#"{"shared":true}"#.utf8)
        let headers = try signer.headers(method: "PUT", pathAndQuery: "/v1/devices/x/mac-screen", body: body)
        #expect(headers["X-Device-Id"] == "6f1c2a4e-0d3b-4c5a-9e7f-112233445566")
        #expect(headers["X-Device-Ts"] == "1800000000")
        let signature = try #require(headers["X-Device-Sig"])
        #expect(Data(base64Encoded: signature)?.count == 64)
        let canonical = DeviceRequestSigner.canonical(method: "PUT", pathAndQuery: "/v1/devices/x/mac-screen", timestamp: 1_800_000_000, body: body)
        #expect(DeviceIdentity.verify(signature: signature, of: Data(canonical.utf8), signingKey: identity.signingKey))
        // Another request's canonical string, or another key, does not verify.
        let other = DeviceRequestSigner.canonical(method: "PUT", pathAndQuery: "/v1/devices/y/mac-screen", timestamp: 1_800_000_000, body: body)
        #expect(!DeviceIdentity.verify(signature: signature, of: Data(other.utf8), signingKey: identity.signingKey))
        #expect(!DeviceIdentity.verify(signature: signature, of: Data(canonical.utf8), signingKey: DeviceIdentity.software().signingKey))
    }

    @Test func publicKeysAreX963AndTheFingerprintIsTheKeysSHA256() throws {
        let identity = DeviceIdentity.software()
        #expect(Data(base64Encoded: identity.signingKey)?.count == 65)
        #expect(Data(base64Encoded: identity.agreementKey)?.first == 0x04)
        let fingerprint = identity.fingerprint
        let expected = SHA256.hash(data: Data(base64Encoded: identity.signingKey)!).map { String(format: "%02x", $0) }.joined()
        #expect(fingerprint == expected)
        #expect(DeviceIdentity.fingerprint(signingKey: identity.signingKey) == fingerprint)
        #expect(DeviceIdentity.fingerprint(signingKey: "not a key") == nil)
        let display = DeviceIdentity.displayFingerprint(fingerprint)
        #expect(display.split(separator: " ").count == 8)
        #expect(display.replacingOccurrences(of: " ", with: "") == String(expected.uppercased().prefix(32)))
    }
}
