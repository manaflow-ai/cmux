import CmuxFuzzSupport
@testable import CmuxAuthRuntime
import Foundation
import Testing

/// Seeded fuzz of what reaches sign-in from outside (plans/cmux-next/chrome-parity/p10-stability.md, task 180):
/// auth callback URLs (any scheme, host, query and `stack_access` cookie), the unverified claims of an access
/// token (its lifetime for the debug log, its email for the approval dialog), the account deletion API's
/// replies and the file token store's `credentials.json`. Garbage, truncated and deeply nested input. Chrome
/// fuzzes the same entry points: its URL parser (url/url_parse_fuzzer.cc, gurl_fuzzer.cc) and its JSON reader
/// (base/json/json_reader_fuzzer.cc).
///
/// The properties:
/// - no input traps;
/// - a callback payload comes only from a cmux callback URL, with non-empty trimmed tokens;
/// - a token's lifetime is its claims' whole seconds when an `Int` holds them, else nil; a claimed email is
///   trimmed, non-empty and at most 320 characters;
/// - a deletion reply at 401 is `unauthorized`, one outside 2xx never completes, one inside 2xx is never
///   refused;
/// - a damaged credentials file reads as tokens or as signed out, and a write reads back.
///
/// It runs only with `CMUX_AUTH_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_AUTH_FUZZ=1 swift test --filter AuthRuntimeFuzzTests
/// CMUX_AUTH_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test --filter AuthRuntimeFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s (p10-stability-016): `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS`
/// replay a failure, and with `CMUX_FUZZ_ARTIFACTS` set a trap leaves its input behind.
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_AUTH_FUZZ"] == "1",
        "set CMUX_AUTH_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct AuthRuntimeFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// One input of the synchronous properties, its choices read from `data` (the libFuzzer entry,
    /// p10-stability-182). Deletion replies and the token store await, so they are not part of it.
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        let branch = rng.below(3)
        let text = String(decoding: rng.bytes(2_048), as: UTF8.self)
        switch branch {
        case 0: try AuthRuntimeFuzzCases.callback(text)
        case 1: try AuthRuntimeFuzzCases.token(text, claims: nil)
        default: try AuthRuntimeFuzzCases.callback("cmux://auth-callback?stack_refresh=r&stack_access=" + text)
        }
    }

    @Test(.timeLimit(.minutes(AuthRuntimeFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("AuthRuntime.oneInput", seed: 0xA070_0180_0001, iterations: 4_000)
        let tapes: [[UInt8]] = [[0], [1], [2], [0, 20, 99, 109, 117, 120, 58, 47, 47, 97, 117, 116, 104]]
        try run.forEachInput(try run.corpus(seeds: tapes.map { Data($0) })) { try Self.oneInput($0) }
    }

    /// Callback URLs damaged by URL-token edits: a payload only from a cmux callback.
    @Test(.timeLimit(.minutes(AuthRuntimeFuzzTests.timeLimitMinutes)))
    func callbackURLsGiveAPayloadOnlyFromACallback() throws {
        let run = try FuzzRun("AuthRuntime.callback", seed: 0xA070_0180_0002, iterations: 20_000)
        let mutator = FuzzMutator(dictionary: AuthRuntimeFuzzCases.urlTokens, maximumEdits: 6, maximumCount: 1 << 12)
        try run.forEachInput(try run.corpus(seeds: AuthRuntimeFuzzCases.callbackSeeds), mutator: mutator) {
            try AuthRuntimeFuzzCases.callback(String(decoding: $0, as: UTF8.self))
        }
    }

    /// Access tokens whose claims hold any `exp`, `iat` and `email`, including numbers no `Int` holds.
    @Test(.timeLimit(.minutes(AuthRuntimeFuzzTests.timeLimitMinutes)))
    func tokenClaimsReadOrAreNil() throws {
        try FuzzRun("AuthRuntime.claims", seed: 0xA070_0180_0003, iterations: 20_000).forEach { rng in
            let claims = AuthRuntimeFuzzCases.claims(&rng)
            let token = try AuthRuntimeFuzzCases.jwt(claims)
            try AuthRuntimeFuzzCases.token(token, claims: claims)
            try AuthRuntimeFuzzCases.token(String(token.prefix(rng.below(token.count + 1))), claims: nil)
        }
    }

    /// Account deletion replies of any status and body.
    @Test(.timeLimit(.minutes(AuthRuntimeFuzzTests.timeLimitMinutes)))
    func deletionRepliesMapToTheirOutcome() async throws {
        let run = try FuzzRun("AuthRuntime.deletion", seed: 0xA070_0180_0004, iterations: 3_000)
        let mutator = FuzzMutator(dictionary: AuthRuntimeFuzzCases.jsonTokens, maximumEdits: 4, maximumCount: 1 << 12)
        try await run.forEachInputAwaiting(try run.corpus(seeds: AuthRuntimeFuzzCases.deletionSeeds), mutator: mutator) { data in
            try await AuthRuntimeFuzzCases.deletion(data)
        }
    }

    /// `credentials.json` damaged anywhere: tokens or signed out, and a write reads back.
    @Test(.timeLimit(.minutes(AuthRuntimeFuzzTests.timeLimitMinutes)))
    func damagedCredentialsReadAsTokensOrSignedOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("auth-fuzz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = try FuzzRun("AuthRuntime.credentials", seed: 0xA070_0180_0005, iterations: 1_000)
        let mutator = FuzzMutator(dictionary: AuthRuntimeFuzzCases.jsonTokens, maximumEdits: 4, maximumCount: 1 << 12)
        try await run.forEachInputAwaiting(try run.corpus(seeds: AuthRuntimeFuzzCases.credentialSeeds), mutator: mutator) { data in
            try await AuthRuntimeFuzzCases.credentials(data, in: folder)
        }
    }
}

/// The fixed cases the fuzz found (p10-stability-180); they run on every `swift test`.
struct AuthRuntimeDecodeTrapTests {
    /// An `exp` or `iat` no `Int` holds gives no lifetime. Before, `Int(exp - now)` trapped on it, in the debug
    /// log line every token refresh writes (`FileStackTokenStore.compareAndSet`), and the app ended.
    @Test(arguments: ["1e300", "-1e300", "9223372036854775807", "1.8e19"])
    func anExpiryNoIntHoldsGivesNoLifetime(exp: String) {
        let token = AuthRuntimeFuzzCases.jwtText(#"{"exp":\#(exp),"iat":0}"#)
        #expect(AccessTokenLifetime(token, now: Date(timeIntervalSince1970: 0)) == nil)
        #expect(AccessTokenLifetime.logFields(token) == "accessExpiresInSec=nil")
    }

    @Test func anIssueTimeNoIntHoldsGivesNoLifetimeLength() throws {
        let token = AuthRuntimeFuzzCases.jwtText(#"{"exp":1000.9,"iat":-1e300}"#)
        let lifetime = try #require(AccessTokenLifetime(token, now: Date(timeIntervalSince1970: 0)))
        #expect(lifetime.expiresInSeconds == 1_000)
        #expect(lifetime.lifetimeSeconds == nil)
    }

    @Test func anOrdinaryTokenKeepsItsLifetime() throws {
        let token = AuthRuntimeFuzzCases.jwtText(#"{"exp":1700003600,"iat":1700000000}"#)
        let lifetime = try #require(AccessTokenLifetime(token, now: Date(timeIntervalSince1970: 1_700_000_600.5)))
        #expect(lifetime.expiresInSeconds == 2_999)
        #expect(lifetime.lifetimeSeconds == 3_600)
    }
}

/// The inputs and properties of ``AuthRuntimeFuzzTests``.
enum AuthRuntimeFuzzCases {
    static let schemes = ["cmux", "cmux-nightly", "cmux-rc", "cmux-dev", "cmux-dev-tag"]
    static let router = AuthCallbackRouter(extraAllowedScheme: "cmux-dev-tag")

    static let urlTokens: [Data] = [
        "cmux://", "CMUX-RC://", "cmux-dev-tag:", "auth-callback", "/auth-callback/", "?", "&", "=", "#", "%", "%00",
        "%2F", "%ZZ", "stack_refresh=", "stack_access=", "[", "]", "%5B%22a%22%2C%22tok%22%5D", "\"", " ", "\u{FEFF}",
        "https://", "@", ":", "..", "//",
    ].map { Data($0.utf8) }

    static let jsonTokens: [Data] = FuzzJSON.tokens + [
        #""deletionPending""#, #""cleanupIncomplete""#, #""error""#, #""account_delete_retryable""#,
        #""account_stack_delete_failed_after_data_delete""#, #""account_delete_failed""#, #""accessToken""#,
        #""refreshToken""#,
    ].map { Data($0.utf8) }

    static let callbackSeeds: [Data] = [
        "cmux://auth-callback?stack_refresh=refresh-1&stack_access=eyJh.eyJlbWFpbCI6ImFAYi5jIn0.sig",
        #"cmux-nightly://auth-callback?stack_refresh=r&stack_access=["user","eyJh.e30.s"]"#,
        "cmux-dev-tag:///auth-callback/?stack_access=a&stack_refresh=%20r%20&stack_refresh=attacker",
        "https://auth-callback?stack_refresh=r&stack_access=a", "cmux://other?stack_refresh=r&stack_access=a",
        "cmux://auth-callback?stack_refresh=&stack_access=a", "cmux://auth-callback", "",
    ].map { Data($0.utf8) }

    static let deletionSeeds: [Data] = ([
        [200, 0] + Array(#"{"ok":true}"#.utf8), [202, 0] + Array(#"{"ok":true,"cleanupIncomplete":true}"#.utf8),
        [202, 0] + Array(#"{"ok":true,"deletionPending":true}"#.utf8), [0x91, 1] + Array("{}".utf8),
        [0xF4, 1] + Array(#"{"error":"account_delete_retryable"}"#.utf8), [0x90, 1] + Array(#"{"error":"account_delete_failed"}"#.utf8),
        [0x98, 1] + Array("<html>".utf8),
    ] as [[UInt8]]).map { Data($0) }

    static let credentialSeeds: [Data] = [
        #"{"accessToken":"a","refreshToken":"r"}"#, #"{"accessToken":null,"refreshToken":"r"}"#, #"{"accessToken":5}"#,
        #"{"refreshToken":""}"#, "[]", "", "{",
    ].map { Data($0.utf8) }

    /// `object` as a token's payload segment: base64url without padding.
    static func jwtText(_ object: String) -> String {
        let payload = Data(object.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJFUzI1NiJ9.\(payload).c2ln"
    }

    static func jwt(_ claims: FuzzJSON) throws -> String {
        jwtText(try claims.text())
    }

    /// Claims with an `exp`, `iat` and `email` of any type, numbers at and past what an `Int` holds.
    static func claims(_ rng: inout FuzzRNG) -> FuzzJSON {
        func number(_ rng: inout FuzzRNG) -> FuzzJSON {
            switch rng.below(6) {
            case 0: return .double([1e300, -1e300, 9.3e18, -9.3e18, 1.8e19, 0.5][rng.below(6)])
            case 1: return .int(rng.oneIn(2) ? .max : .min)
            case 2: return .uint(rng.next())
            case 3: return FuzzJSON.random(&rng, depth: 1)
            default: return .int(Int64(rng.int(in: 1_600_000_000...1_900_000_000)))
            }
        }
        var fields: [String: FuzzJSON] = [:]
        if !rng.oneIn(6) { fields["exp"] = number(&rng) }
        if !rng.oneIn(3) { fields["iat"] = number(&rng) }
        if !rng.oneIn(3) {
            let padding = rng.oneIn(4) ? String(repeating: " ", count: rng.below(4)) : ""
            let local = rng.oneIn(16) ? String(repeating: "a", count: 300 + rng.below(40)) : FuzzJSON.randomString(&rng, limit: 12)
            fields["email"] = rng.oneIn(5) ? FuzzJSON.random(&rng, depth: 1) : .string(padding + local + "@cmux.test" + padding)
        }
        return .object(fields)
    }

    /// A callback URL: a payload only from an allowed scheme's `auth-callback`, its tokens trimmed and non-empty.
    static func callback(_ text: String) throws {
        guard let url = URL(string: text) else { return }
        _ = router.isAuthCallbackURL(url)
        guard let payload = router.callbackPayload(from: url) else { return }
        try FuzzRun.check(router.isAuthCallbackURL(url) && schemes.contains(url.scheme?.lowercased() ?? ""),
                          "a payload from \(text.prefix(120))")
        try FuzzRun.check(payload.refreshToken == payload.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
                          "an untrimmed refresh token")
        try FuzzRun.check(!payload.accessToken.isEmpty && !payload.refreshToken.isEmpty, "an empty callback token")
        try email(of: payload)
    }

    /// A token's lifetime and claimed email; with `claims`, the values they must give.
    static func token(_ token: String, claims: FuzzJSON?) throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let lifetime = AccessTokenLifetime(token, now: now)
        _ = AccessTokenLifetime.logFields(token)
        try email(of: AuthCallbackPayload(refreshToken: "r", accessToken: token))
        guard case .object(let fields)? = claims else { return }
        guard let exp = seconds(fields["exp"]) else {
            try FuzzRun.check(lifetime == nil, "a lifetime from a token without a numeric exp")
            return
        }
        let expiresIn = Int(exactly: (exp - now.timeIntervalSince1970).rounded(.towardZero))
        try FuzzRun.check(lifetime?.expiresInSeconds == expiresIn, "exp \(exp) gave \(String(describing: lifetime))")
        guard let lifetime else { return }
        let length = seconds(fields["iat"]).flatMap { Int(exactly: (exp - $0).rounded(.towardZero)) }
        try FuzzRun.check(lifetime.lifetimeSeconds == length, "exp \(exp) and iat gave length \(String(describing: lifetime.lifetimeSeconds))")
    }

    /// A claim as AccessTokenLifetime reads it: any `NSNumber` JSONSerialization gives (a boolean too), as a Double.
    static func seconds(_ claim: FuzzJSON?) -> Double? {
        guard let claim, let data = try? FuzzJSON.array([claim]).data(),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        return (array.first as? NSNumber)?.doubleValue
    }

    static func email(of payload: AuthCallbackPayload) throws {
        guard let email = payload.claimedEmail else { return }
        try FuzzRun.check(!email.isEmpty && email.count <= 320 && email == email.trimmingCharacters(in: .whitespacesAndNewlines),
                          "claimed email \(email.prefix(40)) is empty, untrimmed or too long")
    }

    /// A deletion reply: the first two bytes the status (little endian, folded into 100-599), the rest the body.
    static func deletion(_ data: Data) async throws {
        let raw = Int(data.first ?? 0) | Int(data.dropFirst().first ?? 0) << 8
        let status = (100...599).contains(raw) ? raw : 100 + raw % 500
        let body = Data(data.dropFirst(2))
        let client = AccountDeletionClient(apiBaseURL: "https://cmux.test/") { request in
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badServerResponse) }
            return (body, response)
        }
        let outcome: Result<AccountDeletionResult, AccountDeletionRequestError>
        do {
            outcome = .success(try await client.deleteAccount(accessToken: "a", refreshToken: "r"))
        } catch let error as AccountDeletionRequestError {
            outcome = .failure(error)
        }
        let pending = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["deletionPending"] as? Bool == true
        switch outcome {
        case .success:
            try FuzzRun.check((200..<300).contains(status) && !pending, "a deletion reply at \(status) completed")
        case .failure(.unauthorized):
            try FuzzRun.check(status == 401, "a reply at \(status) was unauthorized")
        case .failure(.completionUnknown) where (200..<300).contains(status):
            try FuzzRun.check(pending, "a completed reply at \(status) is unknown")
        case .failure(let error):
            try FuzzRun.check(!(200..<300).contains(status) && status != 401, "a reply at \(status) gave \(error)")
        }
    }

    /// `data` as `credentials.json`: the store reads it without a trap, then reads back what it writes over it.
    static func credentials(_ data: Data, in folder: URL) async throws {
        let file = folder.appendingPathComponent("credentials.json", isDirectory: false)
        try data.write(to: file)
        let store = FileStackTokenStore(directory: folder)
        _ = await (store.getStoredAccessToken(), store.getStoredRefreshToken())
        await store.setTokens(accessToken: "access-\(data.count)", refreshToken: "refresh")
        let reread = FileStackTokenStore(directory: folder)
        let written = await reread.getStoredAccessToken()
        try FuzzRun.check(written == "access-\(data.count)", "a written token does not read back")
        try? FileManager.default.removeItem(at: file)
    }
}
