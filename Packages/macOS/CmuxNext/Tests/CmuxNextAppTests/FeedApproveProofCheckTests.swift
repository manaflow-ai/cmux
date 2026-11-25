@testable import CmuxNextApp
import CmuxNextFeedClient
import CryptoKit
import Foundation
import Testing

/// The phone approve proof check, asked of cmux-feed-approve over the app FFI, pinned against
/// what the Swift it replaced did: a proof CryptoKit signs (as the phone's Secure Enclave key
/// does) passes, every changed field fails, and the shown-text digest is the v2 form's.
struct FeedApproveProofCheckTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let key = P256.Signing.PrivateKey()
    static let context = FeedApproveProofCheck.Context(environment: "production", user: "user-1", macInstall: "mac-1")

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// A `user.presence_key.list` value as the owner answers it.
    static func presence(platform: String = "ios", attested: Bool = true, usableFrom: Double? = nil) -> [String: Any] {
        let point = key.publicKey.x963Representation
        let entry: [String: Any] = [
            "install": "phone-1", "platform": platform, "attested": attested,
            "usable_from": usableFrom ?? (now.timeIntervalSince1970 * 1000 - 1000),
            "revoked_at": NSNull(), "install_active": true,
            "jwk": ["kty": "EC", "crv": "P-256",
                    "x": base64URL(point.subdata(in: 1..<33)), "y": base64URL(point.subdata(in: 33..<65))],
        ]
        return ["keys": [entry]]
    }

    static func decision(item: String = "item-1", shown: String = "abc", scope: FeedApproveDecision.Scope? = nil,
                         at: Date = now) throws -> FeedApproveDecision {
        let ts = Int64(at.timeIntervalSince1970 * 1000)
        let bytes = ["cmux-feed-approve-v1", "production", "user-1", "phone-1", "mac-1", item, shown, "allow",
                     scope?.rawValue ?? "once", String(ts)].joined(separator: "\n")
        let signature = try key.signature(for: Data(bytes.utf8)).rawRepresentation
        return FeedApproveDecision(.allow, scope: scope,
                                   proof: .init(install: "phone-1", timestampMs: ts, signature: base64URL(signature)))
    }

    static func check(_ decision: FeedApproveDecision, keys: [String: Any] = presence()) -> Result<Void, FeedApproveProofCheck.Failure> {
        FeedApproveProofCheck.check(decision, by: "phone-1", item: "item-1", shownSHA256: "abc", context: context,
                                    keys: FeedApproveProofCheck.keys(from: keys), now: now)
    }

    static func failure(_ result: Result<Void, FeedApproveProofCheck.Failure>) -> FeedApproveProofCheck.Failure? {
        if case .failure(let failure) = result { return failure }
        return nil
    }

    @Test func aCryptoKitSignedProofPasses() throws {
        #expect(Self.failure(Self.check(try Self.decision())) == nil)
        #expect(Self.failure(Self.check(try Self.decision(scope: .session))) == nil)
    }

    @Test func everyRuleRefusesAsTheSwiftDid() throws {
        #expect(Self.failure(Self.check(FeedApproveDecision(.allow))) == .noProof)
        #expect(Self.failure(Self.check(try Self.decision(item: "item-2"))) == .badSignature)
        #expect(Self.failure(Self.check(try Self.decision(shown: "abd"))) == .badSignature)
        #expect(Self.failure(Self.check(try Self.decision(at: Self.now.addingTimeInterval(-301)))) == .stale)
        #expect(Self.failure(Self.check(try Self.decision(at: Self.now.addingTimeInterval(61)))) == .stale)
        #expect(Self.failure(Self.check(try Self.decision(), keys: [:])) == .noKey)
        #expect(Self.failure(Self.check(try Self.decision(), keys: Self.presence(platform: "android"))) == .notPhone)
        #expect(Self.failure(Self.check(try Self.decision(), keys: Self.presence(attested: false))) == .notAttested)
        let later = Self.now.timeIntervalSince1970 * 1000 + 1000
        #expect(Self.failure(Self.check(try Self.decision(), keys: Self.presence(usableFrom: later))) == .coolingDown)
        #expect(String(describing: FeedApproveProofCheck.Failure.coolingDown) == "coolingDown")
    }

    @Test func theContextComesFromTheInstallToken() {
        let claims = #"{"iss":"https://cmux-api/production","sub":"user-1","inst":"mac-1"}"#
        let token = "h." + Self.base64URL(Data(claims.utf8)) + ".s"
        #expect(FeedApproveProofCheck.context(ofToken: token) == Self.context)
        #expect(FeedApproveProofCheck.context(ofToken: "h.e30.s") == nil)
    }

    @Test func theShownDigestIsTheV2Form() {
        let action: [String: Any] = [
            "tool": "Bash", "summary": "List files", "command": "ls -la\nrm x",
            "input": ["pattern": "*.rs", "path": "/tmp/é", "depth": 3], "truncated": true,
        ]
        // sha256 of "cmux-feed-shown-v2\ntool:4:Bash\nsummary:10:List files\ncommand:11:ls -la\nrm x\n
        // input:4:path:7:/tmp/é\ninput:7:pattern:4:*.rs\ntruncated:1\n", the removed FeedApproveShownText's form.
        #expect(FeedApproveProofCheck.shownSHA256(action: action)
            == "bc6bb01ed22b3f2839399866e1cefe2170979b0c6cd0252ac1903592e35d566c")
    }
}
