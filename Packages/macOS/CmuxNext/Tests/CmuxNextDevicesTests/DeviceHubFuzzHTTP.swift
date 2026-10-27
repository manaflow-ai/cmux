import CmuxFuzzSupport
@testable import CmuxNextDevices
import Foundation

/// One ``DeviceHubClient`` call: its route, the answer that succeeds, and the call itself.
nonisolated struct HubCall: Sendable {
    var method: String
    /// The path after the base URL's path, each segment as the call's ids gave it (not percent-encoded).
    var path: [String]
    var query: [String: String] = [:]
    var good: FuzzJSON
    var perform: @Sendable (DeviceHubClient) async throws -> Void

    static func random(_ rng: inout FuzzRNG, me: String) -> HubCall {
        let a = HubFuzz.id(&rng), b = HubFuzz.id(&rng)
        let scope = rng.element(of: DeviceScope.allCases) ?? .view
        let sessionScope: SessionScope = rng.bool() ? .view : .full
        let flag = rng.bool()
        let none = FuzzJSON.object([:])
        let device = FuzzJSON.object(["device": .object(["id": .string(a), "name": .string(b)])])
        let session = FuzzJSON.object(["session": .object(["id": .string(a)])])
        switch rng.below(17) {
        case 0:
            return HubCall(method: "GET", path: ["v1", "me"], good: .object(["userId": .string(a)])) { _ = try await $0.me() }
        case 1:
            return HubCall(method: "POST", path: ["v1", "devices"], good: device) { _ = try await $0.registerDevice(name: a, platform: .macos) }
        case 2:
            return HubCall(method: "GET", path: ["v1", "devices"], good: .object(["devices": .array([.object(["id": .string(a)])])])) {
                _ = try await $0.devices()
            }
        case 3:
            return HubCall(method: "PATCH", path: ["v1", "devices", a], good: device) { _ = try await $0.renameDevice(a, name: b) }
        case 4:
            return HubCall(method: "DELETE", path: ["v1", "devices", a], good: none) { try await $0.removeDevice(a) }
        case 5:
            return HubCall(method: "POST", path: ["v1", "devices", me, "sign-out"], good: none) { try await $0.signOutDevice() }
        case 6:
            return HubCall(method: "PUT", path: ["v1", "devices", me, "mac-screen"], good: device) {
                _ = try await $0.setMacScreenShared(flag)
            }
        case 7:
            return HubCall(method: "GET", path: ["v1", "permissions"], query: ["host": a],
                           good: .object(["permissions": .array([.object(["viewerId": .string(b)])])])) {
                _ = try await $0.permissions(host: a)
            }
        case 8:
            return HubCall(method: "PUT", path: ["v1", "permissions", a, b],
                           good: .object(["permission": .object(["viewerId": .string(b), "scope": .string("full")])])) {
                _ = try await $0.setPermission(host: a, viewer: b, scope: scope)
            }
        case 9:
            return HubCall(method: "POST", path: ["v1", "sessions"], good: session) {
                _ = try await $0.requestSession(host: b, scope: sessionScope)
            }
        case 10:
            return HubCall(method: "POST", path: ["v1", "sessions", a, "decision"], good: session) {
                _ = try await $0.decide(session: a, decision: .once, scope: sessionScope)
            }
        case 11:
            return HubCall(method: "POST", path: ["v1", "sessions", a, "end"], good: none) { try await $0.endSession(a, reason: b) }
        case 12:
            return HubCall(method: "POST", path: ["v1", "sessions", a, "ice"], good: .object(["ice": .array([])])) {
                _ = try await $0.sessionICE(a)
            }
        case 13:
            return HubCall(method: "GET", path: ["v1", "relays"], good: .object(["relays": .array([])])) { _ = try await $0.relays() }
        case 14:
            let update = RelayUpdate(id: a, name: b, urls: [], authMode: .static, sealed: [:], enabled: flag, priority: 0)
            return HubCall(method: "PUT", path: ["v1", "relays", a], good: .object(["relay": .object(["id": .string(a)])])) {
                _ = try await $0.putRelay(update)
            }
        case 15:
            return HubCall(method: "DELETE", path: ["v1", "relays", a], good: none) { try await $0.deleteRelay(a) }
        default:
            return HubCall(method: "GET", path: ["v1", "audit"], query: ["device": a], good: .object(["entries": .array([])])) {
                _ = try await $0.audit(limit: 50, device: a)
            }
        }
    }
}

/// One signed call against a scripted hub: the account exchange's answer, then the call's (the same
/// answer again when the client exchanges and retries once after an account refusal).
nonisolated struct HubHTTPCase {
    enum Reply: Sendable {
        case good
        /// A refusal; `code` is nil when the body is not the protocol's error object.
        case failure(status: Int, code: String?, message: String?)
        /// A 2xx whose body is not the answer.
        case garbage
    }

    enum Outcome {
        case value
        case error(DeviceHubError)
        case decoding
        case valueOrDecoding
    }

    let identity: DeviceIdentity
    let call: HubCall
    let basePath: String
    let token: String
    let tokenFails: Bool
    let exchange: Reply
    let exchangeWire: (Int, String)
    let answer: Reply
    let answerWire: (Int, String)

    init(_ rng: inout FuzzRNG, identity: DeviceIdentity) throws {
        self.identity = identity
        call = HubCall.random(&rng, me: identity.id)
        basePath = rng.element(of: ["", "/api", "/api/"]) ?? ""
        let token = HubFuzz.plain(&rng, limit: 24)
        self.token = token
        tokenFails = rng.oneIn(16)
        let user = FuzzJSON.randomString(&rng)
        var session = FuzzJSON.object(["session": .string(token), "userId": .string(user)])
        switch rng.below(4) {
        case 0: session = session.setting("expiresAt", .int(1_800_003_600_000))
        case 1: session = session.setting("expiresAt", .int(0))
        case 2: session = session.setting("expiresAt", FuzzJSON.random(&rng, of: [.bool, .string, .array]))
        default: break
        }
        let exchangeReply = try Self.reply(&rng, good: session)
        exchange = exchangeReply.0
        exchangeWire = exchangeReply.1
        let answerReply = try Self.reply(&rng, good: call.good)
        answer = answerReply.0
        answerWire = answerReply.1
    }

    /// The good answer half the time; else a refusal (with or without the protocol's error body) or a
    /// 2xx carrying random bytes or a JSON value that is not the answer.
    static func reply(_ rng: inout FuzzRNG, good: FuzzJSON) throws -> (Reply, (Int, String)) {
        switch rng.below(4) {
        case 0, 1:
            return (.good, (200, try good.text()))
        case 2:
            let status = rng.int(in: 400...599)
            guard rng.bool() else {
                let body = try rng.oneIn(4) ? "" : FuzzJSON.random(&rng, notOf: [.object]).text()
                return (.failure(status: status, code: nil, message: nil), (status, body))
            }
            let code = rng.oneIn(4) ? FuzzJSON.randomString(&rng) : (rng.element(of: DeviceHubError.Code.table.map(\.1)) ?? "")
            let message: String? = rng.bool() ? FuzzJSON.randomString(&rng) : nil
            var detail = FuzzJSON.object(["code": .string(code)])
            if let message { detail = detail.setting("message", .string(message)) }
            return (.failure(status: status, code: code, message: message), (status, try FuzzJSON.object(["error": detail]).text()))
        default:
            let status = rng.element(of: [200, 201, 202]) ?? 200
            let body = try rng.bool() ? String(decoding: rng.bytes(64), as: UTF8.self)
                : FuzzJSON.random(&rng, notOf: [.object]).text()
            return (.garbage, (status, body))
        }
    }

    /// The error a refusal must give (`DeviceHubError.from`'s contract, PROTOCOL.md errors).
    static func error(status: Int, code: String?, message: String?) -> DeviceHubError {
        guard let code else { return status == 401 ? .notSignedIn : .http(status: status) }
        return .server(status: status, code: DeviceHubError.Code(code), message: message ?? "")
    }

    var expected: Outcome {
        if tokenFails { return .error(.notSignedIn) }
        switch exchange {
        case .good: break
        case let .failure(status, code, message): return .error(Self.error(status: status, code: code, message: message))
        case .garbage: return .decoding
        }
        switch answer {
        case .good: return .value
        case let .failure(status, code, message): return .error(Self.error(status: status, code: code, message: message))
        case .garbage: return .valueOrDecoding
        }
    }

    func check(on stub: StubHub) async throws {
        _ = stub.drainRequests()
        let exchangeWire = exchangeWire, answerWire = answerWire
        stub.setHandler { request in
            Self.encodedPath(request.url).hasSuffix("/v1/auth/stack") ? exchangeWire : answerWire
        }
        guard let base = URL(string: "https://\(stub.host)\(basePath)") else {
            throw FuzzError.property("no base URL for \(basePath)", location: "HubHTTPCase")
        }
        let tokens: DeviceHubAccountToken
        if tokenFails {
            tokens = DeviceHubAccountToken({ () async throws -> String in throw URLError(.userAuthenticationRequired) })
        } else {
            tokens = DeviceHubAccountToken({ "stack-token" })
        }
        let client = DeviceHubClient(baseURL: base, identity: identity, tokens: tokens, session: StubHub.session, now: fixedNow)
        let outcome: Result<Void, any Error>
        do {
            try await call.perform(client)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try check(outcome)
        try check(requests: stub.drainRequests())
    }

    private func check(_ outcome: Result<Void, any Error>) throws {
        let route = "\(call.method) \(call.path)"
        switch (expected, outcome) {
        case (.value, .success), (.valueOrDecoding, .success):
            return
        case let (.error(want), .failure(error)):
            try FuzzRun.check((error as? DeviceHubError) == want, "\(route) threw \(error), not \(want)")
        case let (.decoding, .failure(error)), let (.valueOrDecoding, .failure(error)):
            guard case .decoding? = error as? DeviceHubError else {
                throw FuzzError.property("\(route) threw \(error), not a decoding error", location: "HubHTTPCase")
            }
        default:
            throw FuzzError.property("\(route) gave \(outcome), expected \(expected)", location: "HubHTTPCase")
        }
    }

    /// Every call request is the call's route with each id in its own segment, carries the account
    /// session, and is signed by this device over the method, path, query and body it went with.
    private func check(requests: [RecordedRequest]) throws {
        let prefix = basePath.isEmpty ? [] : ["api"]
        var calls = 0
        for request in requests {
            let path = Self.encodedPath(request.url)
            if path.hasSuffix("/v1/auth/stack") {
                try FuzzRun.check(request.method == "POST" && request.header(DeviceRequestSigner.signatureHeader) == nil,
                                  "the account exchange went as \(request.method), signed: \(request.header(DeviceRequestSigner.signatureHeader) != nil)")
                try FuzzRun.check(request.jsonBody?["token"] as? String == "stack-token", "the exchange did not send the Stack token")
                continue
            }
            calls += 1
            let segments = path.split(separator: "/").map { String($0).removingPercentEncoding }
            try FuzzRun.check(request.method == call.method && segments == (prefix + call.path).map(Optional.some),
                              "\(call.method) \(call.path) went to \(request.method) \(path)")
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for (name, value) in call.query {
                try FuzzRun.check(items.first { $0.name == name }?.value == value, "\(request.url) does not carry \(name)=\(value)")
            }
            try FuzzRun.check(request.header("Authorization") == "Bearer \(token)", "a call without the account session")
            try FuzzRun.check(request.header(DeviceRequestSigner.idHeader) == identity.id
                && request.header(DeviceRequestSigner.timestampHeader) == "1800000000", "a call without this device's id or time")
            let canonical = DeviceRequestSigner.canonical(method: request.method, pathAndQuery: request.pathAndQuery,
                                                          timestamp: 1_800_000_000, body: request.body)
            let signed = DeviceIdentity.verify(signature: request.header(DeviceRequestSigner.signatureHeader) ?? "",
                                               of: Data(canonical.utf8), signingKey: identity.signingKey)
            try FuzzRun.check(signed, "\(request.method) \(request.pathAndQuery) is not signed over what it sent")
        }
        try FuzzRun.check(calls <= 2, "\(calls) requests for one call (one retry at most)")
        if case .value = expected { try FuzzRun.check(calls >= 1, "a call that succeeded without a request") }
    }

    static func encodedPath(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
    }
}
