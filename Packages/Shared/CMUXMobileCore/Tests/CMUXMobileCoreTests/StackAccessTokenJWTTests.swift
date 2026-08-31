import CryptoKit
import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct StackAccessTokenJWTTests {
    private let projectID = "project-1"

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeKeyAndJWK(kid: String = "kid-1") -> (P256.Signing.PrivateKey, StackAccessTokenJWT.JWK) {
        let privateKey = P256.Signing.PrivateKey()
        let x963 = privateKey.publicKey.x963Representation
        let x = x963.subdata(in: 1..<33)
        let y = x963.subdata(in: 33..<65)
        return (privateKey, StackAccessTokenJWT.JWK(
            kty: "EC", crv: "P-256", x: base64URL(x), y: base64URL(y), kid: kid
        ))
    }

    private func sign(
        _ privateKey: P256.Signing.PrivateKey,
        kid: String = "kid-1",
        sub: String = "user-1",
        aud: String = "project-1",
        exp: TimeInterval = Date().timeIntervalSince1970 + 600
    ) throws -> String {
        let header = base64URL(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": kid]))
        let claims = base64URL(try JSONSerialization.data(withJSONObject: ["sub": sub, "aud": aud, "exp": exp]))
        let signature = try privateKey.signature(for: SHA256.hash(data: Data("\(header).\(claims)".utf8)))
        return "\(header).\(claims).\(base64URL(signature.rawRepresentation))"
    }

    @Test func verifiesAValidToken() throws {
        let (key, jwk) = makeKeyAndJWK()
        let token = try sign(key)
        #expect(try StackAccessTokenJWT.verifiedUserID(
            token: token, keys: [jwk], projectID: projectID
        ) == "user-1")
    }

    @Test func rejectsWrongAudienceAndUserClasses() throws {
        let (key, jwk) = makeKeyAndJWK()
        for aud in ["project-1:anon", "project-1:restricted", "other"] {
            let token = try sign(key, aud: aud)
            #expect(throws: StackAccessTokenJWT.VerificationError.self) {
                try StackAccessTokenJWT.verifiedUserID(token: token, keys: [jwk], projectID: projectID)
            }
        }
    }

    @Test func rejectsExpiredTokens() throws {
        let (key, jwk) = makeKeyAndJWK()
        let token = try sign(key, exp: Date().timeIntervalSince1970 - 3600)
        #expect(throws: StackAccessTokenJWT.VerificationError.self) {
            try StackAccessTokenJWT.verifiedUserID(token: token, keys: [jwk], projectID: projectID)
        }
    }

    @Test func rejectsWrongKeySignatures() throws {
        let (_, jwk) = makeKeyAndJWK()
        let (rogueKey, _) = makeKeyAndJWK(kid: "kid-1")
        let token = try sign(rogueKey)
        #expect(throws: StackAccessTokenJWT.VerificationError.self) {
            try StackAccessTokenJWT.verifiedUserID(token: token, keys: [jwk], projectID: projectID)
        }
    }

    @Test func unknownKidSignalsRefetch() throws {
        let (key, jwk) = makeKeyAndJWK(kid: "kid-old")
        let token = try sign(key, kid: "kid-new")
        #expect(throws: StackAccessTokenJWT.VerificationError.unknownKeyID) {
            try StackAccessTokenJWT.verifiedUserID(token: token, keys: [jwk], projectID: projectID)
        }
    }

    @Test func opaqueTokensSignalFallback() {
        #expect(throws: StackAccessTokenJWT.VerificationError.notAJWT) {
            try StackAccessTokenJWT.verifiedUserID(token: "opaque-token", keys: [], projectID: projectID)
        }
    }
}
