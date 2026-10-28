import CmuxInstallAuthCore
import CryptoKit
import Foundation

/// A test owner that verifies signatures from the actual Mac file signer.
actor MacTeamAuthOwner: InstallAuthTransport {
    enum Failure: Error { case invalidRequest }
    private var keys: [String: P256.Signing.PublicKey] = [:]
    private var contexts: [String: (install: String, team: String?, prefix: String)] = [:]
    private var denied: Set<String> = []
    private var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    private let held = AsyncStream<Void>.makeStream()
    private(set) var requestedTeams: [String] = []
    /// Whether the held team token request's task was cancelled when it was let go.
    private(set) var cancelledAtToken: Bool?
    private(set) var registrations = 0
    private(set) var grants: [[String]] = []

    func deny(_ team: String) { denied.insert(team) }
    func holdNextTeamToken() { hold = true }
    func waitUntilHeld() async { var iterator = held.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { pending?.resume(); pending = nil }

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        guard let body = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw Failure.invalidRequest }
        func reply(_ body: [String: Any], status: Int = 200) throws -> (status: Int, body: Data) {
            (status, try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        }
        if path == "/v1/ops" {
            guard bearer == "test-session" else { throw Failure.invalidRequest }
            if body["op"] as? String == "user.ensure" { return try reply(["ok": true, "value": ["id": "user_1", "stack_user_id": "stack_1"]]) }
            guard body["op"] as? String == "install.register", let params = body["params"] as? [String: Any],
                  let jwk = params["public_jwk"] as? [String: String], let x = jwk["x"].flatMap(Data.init(base64URLEncoded:)),
                  let y = jwk["y"].flatMap(Data.init(base64URLEncoded:)) else { throw Failure.invalidRequest }
            registrations += 1
            grants.append(params["op_classes"] as? [String] ?? [])
            let install = "inst_\(registrations)"
            keys[install] = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
            return try reply(["ok": true, "value": ["id": install]])
        }
        if path == "/v1/auth/challenge" {
            guard let install = body["install"] as? String, keys[install] != nil else { throw Failure.invalidRequest }
            let team = body["team"] as? String, nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            if let team { requestedTeams.append(team) }
            let prefix = team.map { "cmux-auth-team-v1\nstaging\n\(install)\n\($0)\n" } ?? "cmux-auth-v1\nstaging\n\(install)\n"
            contexts[nonce] = (install, team, prefix)
            return try reply(["nonce": nonce, "message_prefix": prefix])
        }
        guard path == "/v1/auth/token", let nonce = body["nonce"] as? String,
              let context = contexts.removeValue(forKey: nonce), body["install"] as? String == context.install,
              let key = keys[context.install], let signature = (body["signature"] as? String).flatMap(Data.init(base64URLEncoded:)) else { throw Failure.invalidRequest }
        let proof = signature.count == 64 ? try P256.Signing.ECDSASignature(rawRepresentation: signature) : try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(proof, for: Data((context.prefix + nonce).utf8)) else { throw Failure.invalidRequest }
        if let team = context.team, denied.contains(team) { return try reply(["code": "auth.forbidden"], status: 403) }
        if context.team != nil, hold {
            hold = false
            await withCheckedContinuation { pending = $0; held.continuation.yield(()) }
            cancelledAtToken = Task.isCancelled
        }
        let team = context.team ?? "team_" + String(repeating: "c", count: 20)
        let claims: [String: Any] = ["iss": "https://cmux-api/staging", "sub": "user_1", "inst": context.install, "team": team, "grant": "grant_1", "aud": "api"]
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]).base64URLEncoded
        return try reply(["access_token": "eyJhbGciOiJFUzI1NiJ9.\(payload).c2ln", "user": "user_1", "install": context.install,
                          "team": team, "grant": "grant_1", "expires_at": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000])
    }
}
