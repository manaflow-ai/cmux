import CmuxInstallAuthCore
import CryptoKit
import Foundation
@testable import CmuxNextCloud

/// Independent Native and backend authorities. Both consume the actual Mac install-key proof.
actor NativeDeviceTestWorld: InstallAuthTransport, NativeDeviceTransport {
    enum Failure: Error { case invalid, lostReply }
    nonisolated let origin = URL(string: "https://vm.test")!
    let auth = MacTeamAuthOwner(user: NativeDeviceTestWorld.user)
    private let scopes: [NativeDeviceScope]
    private var devices: [[String: String]] = []
    private var networks: [String: [String: String]] = [:]
    private var spent: Set<String> = []
    private var loseEnroll = false, loseBind = false, hold = false
    private var pending: CheckedContinuation<Void, Never>?
    private let held = AsyncStream<Void>.makeStream()
    private var badPolicy: String?
    private var badAck = false
    private var oldDevice = false
    private var beforePolicy: (@Sendable () async -> Void)?
    private(set) var requests: [Data] = []
    private(set) var enrollments = 0
    private(set) var deletions = 0
    private(set) var binds = 0
    private(set) var bindKeys: [String] = []
    private(set) var proofNonces: [String] = []
    private(set) var signedReadsWithCredentials = 0
    init(scopes: [NativeDeviceScope]) { self.scopes = scopes }
    func loseEnrollmentReply() { loseEnroll = true }
    func loseBindingReply() { loseBind = true }
    func setBadPolicy(_ field: String) { badPolicy = field }
    func setBadAck() { badAck = true }
    func includeLegacyDevice() { oldDevice = true }
    func onPolicy(_ action: @escaping @Sendable () async -> Void) { beforePolicy = action }
    func holdEnrollment() { hold = true }
    func waitUntilHeld() async { var it = held.stream.makeAsyncIterator(); _ = await it.next() }
    func release() { pending?.resume(); pending = nil }
    static let project = "project_1"
    static let user = "user_" + digest("stack:\(project):stack_1")
    static func team(_ tenant: String) -> String { "team_" + digest("stack-team:\(project):\(tenant)") }
    private static func digest(_ value: String) -> String { String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)) }
    static func session(_ account: String = "stack_1", project: String = NativeDeviceTestWorld.project) -> String {
        let bytes = try! JSONSerialization.data(withJSONObject: ["sub": account, "iss": "https://api.stack-auth.com/api/v1/projects/\(project)"])
        return "e30.\(bytes.base64URLEncoded).sig"
    }
    private func claims(_ token: String) throws -> [String: String] {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let bytes = Data(base64URLEncoded: String(parts[1])),
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: String] else { throw Failure.invalid }
        return value
    }
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        requests.append(json)
        let body = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        guard path == "/v1/ops", let op = body["op"] as? String, op.hasPrefix("host.") else {
            return try await auth.post(path, json: json, bearer: bearer, headers: headers)
        }
        let token = try claims(bearer ?? "")
        guard let scope = scopes.first(where: { $0.team == token["team"] }), let install = token["inst"], token["sub"] == Self.user,
              let point = await auth.publicKey(install)?.base64EncodedString(), let params = body["params"] as? [String: Any] else { throw Failure.invalid }
        let host = "host_" + String(scope.team.dropFirst(5))
        if op == "host.enroll" {
            var value: [String: Any] = ["id": host, "owner_user": Self.user, "enrolled_by": install]
            if let network = networks[scope.team] { value["network"] = network; value["wg_public_key"] = network["wg"] }
            return (200, try data(["ok": true, "value": value]))
        }
        guard op == "host.network.bind", let device = params["device"] as? String, let wg = params["wg_public_key"] as? String,
              params["host"] as? String == host, params["mesh"] as? String == scope.mesh,
              let row = devices.first(where: { $0["id"] == device }), row["wgPublicKey"] == wg, row["installPublicKey"] == point,
              let proof = params["proof"] as? [String: Any], let key = body["idempotency_key"] as? String else { throw Failure.invalid }
        try verify(proof, purpose: "overlay-policy", target: device, point: point)
        bindKeys.append(key)
        if networks[scope.team] == nil { binds += 1 }
        let network = ["state": "confirmed", "tenant": scope.tenant, "mesh": scope.mesh, "device": device, "wg": wg]
        networks[scope.team] = network
        if loseBind { loseBind = false; throw Failure.lostReply }
        return (200, try data(["ok": true, "value": ["host": badAck ? "host_wrong" : host, "network": network]]))
    }

    func send(method: String, path: String, body: Data?, bearer: String?, tenant: String?) async throws -> (status: Int, body: Data) {
        if let body { requests.append(body) }
        if path.hasSuffix("/signed/overlay-policy") {
            if bearer != nil || tenant != nil { signedReadsWithCredentials += 1; throw Failure.invalid }
            let id = path.split(separator: "/")[2]
            guard let row = devices.first(where: { $0["id"] == String(id) }), let point = row["installPublicKey"], let body,
                  let proof = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw Failure.invalid }
            try verify(proof, purpose: "overlay-policy", target: String(id), point: point)
            let action = beforePolicy; beforePolicy = nil
            await action?()
            var policy: [String: Any] = ["tenantId": row["tenant"]!, "meshId": row["meshId"]!, "deviceId": String(id),
                                        "wgPublicKey": row["wgPublicKey"]!, "installPublicKey": point, "accountCredential": "must-not-persist-policy"]
            if let badPolicy { if badPolicy == "missingTenant" { policy.removeValue(forKey: "tenantId") } else { policy[badPolicy] = "wrong" } }
            return (200, try data(policy))
        }
        guard let bearer, try claims(bearer)["sub"] == "stack_1", let scope = scopes.first(where: { $0.tenant == tenant }) else { throw Failure.invalid }
        if method == "DELETE" {
            let id = String(path.split(separator: "/").last!)
            devices.removeAll(where: { $0["id"] == id }); deletions += 1
            return (204, Data())
        }
        guard path == "/v1/meshes/\(scope.mesh)/devices" else { throw Failure.invalid }
        if method == "GET" {
            var items: [[String: Any]] = devices.filter { $0["meshId"] == scope.mesh }.map { $0 }
            if oldDevice { items.append(["id": "dev_" + String(repeating: "z", count: 26), "meshId": scope.mesh,
                                         "wgPublicKey": "legacy", "installPublicKey": NSNull()]) }
            return (200, try data(["items": items]))
        }
        guard method == "POST", let body, let params = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let point = params["installPublicKey"] as? String, let wg = params["wgPublicKey"] as? String,
              let name = params["name"] as? String, point == (await auth.publicKey("inst_1"))?.base64EncodedString() else { throw Failure.invalid }
        try verify(params, purpose: "enroll", target: scope.mesh, point: point, wg: wg, name: name)
        enrollments += 1
        let id = "dev_" + String(repeating: "0", count: 25) + String(enrollments)
        let row = ["id": id, "tenant": scope.tenant, "meshId": scope.mesh, "wgPublicKey": wg, "installPublicKey": point]
        devices.append(row)
        if hold { hold = false; await withCheckedContinuation { pending = $0; held.continuation.yield(()) } }
        if loseEnroll { loseEnroll = false; throw Failure.lostReply }
        return (201, try data(["device": row]))
    }

    private func verify(_ proof: [String: Any], purpose: String, target: String, point: String, wg: String = "", name: String = "") throws {
        guard let at = proof["signedAt"] as? Int64, abs(Int64(Date().timeIntervalSince1970 * 1000) - at) <= 120_000,
              let nonce = proof["nonce"] as? String, nonce.utf8.count == 22,
              let raw = (proof["signature"] as? String).flatMap({ Data(base64Encoded: $0) }), raw.count == 64,
              let keyBytes = Data(base64Encoded: point) else { throw Failure.invalid }
        let message = ["cmux-mesh-v1", purpose, target, wg, point, name, String(at), nonce].joined(separator: "\n")
        guard !spent.contains(message), try P256.Signing.PublicKey(x963Representation: keyBytes).isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: raw), for: Data(message.utf8)) else { throw Failure.invalid }
        spent.insert(message); proofNonces.append(nonce)
    }
}
