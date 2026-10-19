public import CmuxInstallAuthCore
import CryptoKit
public import Foundation

/// Enrolls a Mac device and confirms its backend host identity. No tunnel or serving role is started.
/// Keep one instance per sign-in/mesh. On sign-out call `revoke` before ending the Stack session.
public actor NativeDeviceEnrollment {
    private let scope: NativeDeviceScope
    private let identity: MacInstallIdentity
    private let root: URL
    private let native: any NativeDeviceTransport
    private let nativeOrigin: URL
    private let session: InstallAuthClient.SessionToken
    private let name: String
    private var generation: UInt64 = 0
    private var revoked = false
    private var inflight: Task<NativeDeviceBinding, Error>?
    private var saved: (context: NativeInstallContext, store: NativeDeviceStore)?

    public init(scope: NativeDeviceScope, identity: MacInstallIdentity, paths: CloudPaths,
                native: any NativeDeviceTransport, session: @escaping InstallAuthClient.SessionToken, name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 63, name.first!.isASCII, name.first!.isLetter || name.first!.isNumber,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._ -".contains($0)) }) else { throw NativeDeviceEnrollmentError.invalidScope }
        nativeOrigin = try NativeDeviceScope.canonicalOrigin(native.origin)
        self.scope = scope; self.identity = identity; root = paths.root; self.native = native; self.session = session; self.name = name
    }

    public func enroll() async throws -> NativeDeviceBinding {
        guard !revoked else { throw NativeDeviceEnrollmentError.revoked }
        if let inflight { return try await inflight.value }
        let epoch = generation
        let task = Task { try await self.perform(epoch: epoch) }
        inflight = task
        defer { if inflight == task { inflight = nil } }
        return try await task.value
    }

    /// Stop admitting enrollments. Sign-out also calls `revoke` while its Stack session is available.
    public func stop() { generation &+= 1; revoked = true }

    /// Drain an enrollment already on the wire, then delete the Native device as its original user.
    public func revoke() async throws {
        stop()
        _ = await inflight?.result
        guard let saved else { return }
        let lock = try saved.store.lock()
        defer { withExtendedLifetime(lock) {} }
        var record = try saved.store.loadOrCreate()
        guard let device = record.device else { return }
        let bearer = try await sessionBearer(saved.context)
        let response = try await native.send(method: "DELETE", path: "/v1/devices/\(device)", body: nil, bearer: bearer, tenant: scope.tenant)
        guard (200..<300).contains(response.status) || response.status == 404 else { throw NativeDeviceEnrollmentError.refused(response.status) }
        record.device = nil
        try saved.store.save(record)
    }

    private func perform(epoch: UInt64) async throws -> NativeDeviceBinding {
        let context = try await identity.nativeContext(team: scope.team)
        try await check(context, epoch)
        let parts = ["account": context.user, "install": context.install, "environment": context.environment,
                     "team": scope.team, "tenant": scope.tenant, "mesh": scope.mesh, "native": nativeOrigin.absoluteString]
        let namespace = String(decoding: try JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys]), as: UTF8.self)
        let store = NativeDeviceStore(root: root, namespace: namespace, secret: context.secureStorage ? KeychainNativeDeviceSecret(root: root) : nil)
        let lock = try store.lock()
        defer { withExtendedLifetime(lock) {} }
        saved = (context, store)
        var record = try store.loadOrCreate()
        let wg = try record.key.publicKey.rawRepresentation.base64EncodedString()
        let host: NativeEnrollmentHost = try await owner("host.enroll", NativeHostParams(name: name), key: "native-host:\(hash(namespace + name))", context: context)
        try await check(context, epoch)
        guard host.owner_user == context.user, host.enrolled_by == context.install, host.kind != "server", host.orphaned != true else { throw NativeDeviceEnrollmentError.invalidIdentity }
        if let network = host.network {
            guard network.tenant == scope.tenant, network.mesh == scope.mesh, host.wg_public_key == wg,
                  NativeDeviceScope.isDevice(network.device), record.device == nil || record.device == network.device else { throw NativeDeviceEnrollmentError.invalidIdentity }
            record.device = network.device
        }
        if record.device == nil {
            let bearer = try await sessionBearer(context)
            try await check(context, epoch)
            let listed: NativeDeviceList = try await readNative("GET", "/v1/meshes/\(scope.mesh)/devices", bearer: bearer)
            try await check(context, epoch)
            let candidates = listed.items.filter { $0.wgPublicKey == wg }
            guard candidates.count <= 1 else { throw NativeDeviceEnrollmentError.invalidIdentity }
            let device: NativeDeviceDescription
            if let found = candidates.first { device = found }
            else {
                let proof = try await proof("enroll", target: scope.mesh, wg: wg, name: name, context: context)
                try await check(context, epoch)
                let params = NativeEnrollParams(name: name, wgPublicKey: wg, installPublicKey: context.point, signedAt: proof.signedAt, nonce: proof.nonce, signature: proof.signature)
                let response: NativeDeviceReply = try await readNative("POST", "/v1/meshes/\(scope.mesh)/devices", body: JSONEncoder().encode(params), bearer: bearer)
                device = response.device
            }
            guard NativeDeviceScope.isDevice(device.id), device.meshId == scope.mesh, device.wgPublicKey == wg, device.installPublicKey == context.point else { throw NativeDeviceEnrollmentError.invalidIdentity }
            record.device = device.id
            try store.save(record) // Checkpoint the locator before another await, including sign-out or a lost backend reply.
        }
        try await check(context, epoch)
        guard let device = record.device else { throw NativeDeviceEnrollmentError.invalidState }
        let readProof = try await proof("overlay-policy", target: device, context: context)
        let policy: NativeDevicePolicyIdentity = try await readNative("POST", "/v1/devices/\(device)/signed/overlay-policy", body: JSONEncoder().encode(readProof))
        try await check(context, epoch)
        guard policy.tenantId == scope.tenant, policy.meshId == scope.mesh, policy.deviceId == device,
              policy.wgPublicKey == wg, policy.installPublicKey == context.point else { throw NativeDeviceEnrollmentError.invalidIdentity }
        try store.save(record)
        // The policy read spent its nonce. Backend verification needs its own fresh proof.
        let bindProof = try await proof("overlay-policy", target: device, context: context)
        let ack: NativeBindingAck = try await owner("host.network.bind", NativeBindParams(host: host.id, mesh: scope.mesh, device: device, wg_public_key: wg, proof: bindProof),
                                                   key: "native-bind:\(hash(namespace + host.id + device + wg))", context: context)
        try await check(context, epoch)
        guard ack.host == host.id, ack.network.state == "confirmed", ack.network.tenant == scope.tenant,
              ack.network.mesh == scope.mesh, ack.network.device == device else { throw NativeDeviceEnrollmentError.invalidIdentity }
        return NativeDeviceBinding(host: host.id, team: scope.team, tenant: scope.tenant, mesh: scope.mesh, device: device, wgPublicKey: wg)
    }

    private func check(_ context: NativeInstallContext, _ epoch: UInt64) async throws {
        guard !revoked, epoch == generation else { throw NativeDeviceEnrollmentError.revoked }
        try await identity.nativeCheck(context)
        guard !revoked, epoch == generation else { throw NativeDeviceEnrollmentError.revoked }
    }
    private func sessionBearer(_ context: NativeInstallContext) async throws -> String {
        let bearer = try await session(), pieces = bearer.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let data = Data(base64URLEncoded: String(pieces[1])),
              let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any], claims["sub"] as? String == context.account,
              let issuer = claims["iss"] as? String, issuer.hasPrefix("https://api.stack-auth.com/api/v1/projects/") else { throw NativeDeviceEnrollmentError.signedOut }
        let project = String(issuer.dropFirst("https://api.stack-auth.com/api/v1/projects/".count))
        guard !project.isEmpty, project.utf8.count <= 128, project.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }),
              context.user == "user_" + String(hash("stack:\(project):\(context.account)").prefix(20)) else { throw NativeDeviceEnrollmentError.signedOut }
        let shared = "team_" + String(hash("stack-team:\(project):\(scope.tenant)").prefix(20))
        let personal = "team_" + String(hash("personal:\(context.user)").prefix(20))
        guard scope.team == shared || scope.team == personal else { throw NativeDeviceEnrollmentError.invalidScope }
        return bearer
    }
    private func proof(_ purpose: String, target: String, wg: String = "", name: String = "", context: NativeInstallContext) async throws -> NativeDeviceProof {
        let at = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0).base64URLEncoded }
        let message = ["cmux-mesh-v1", purpose, target, wg, context.point, name, String(at), nonce].joined(separator: "\n")
        return NativeDeviceProof(signedAt: at, nonce: nonce, signature: try await identity.nativeSign(message, context: context))
    }
    private func owner<T: Decodable & Sendable, P: Encodable & Sendable>(_ op: String, _ params: P, key: String, context: NativeInstallContext) async throws -> T {
        let response = try await identity.nativeOwnerPost(JSONEncoder().encode(NativeOwnerCall(op: op, params: params, idempotency_key: key)), context: context)
        guard response.status == 200, response.body.count <= 1_048_576 else { throw NativeDeviceEnrollmentError.refused(response.status) }
        let decoded = try JSONDecoder().decode(NativeOwnerReply<T>.self, from: response.body)
        guard decoded.ok, let value = decoded.value else { throw NativeDeviceEnrollmentError.invalidIdentity }
        return value
    }
    private func readNative<T: Decodable & Sendable>(_ method: String, _ path: String, body: Data? = nil, bearer: String? = nil) async throws -> T {
        let reply = try await native.send(method: method, path: path, body: body, bearer: bearer, tenant: bearer == nil ? nil : scope.tenant)
        guard reply.status == 200 || reply.status == 201, reply.body.count <= 1_048_576 else { throw NativeDeviceEnrollmentError.refused(reply.status) }
        return try JSONDecoder().decode(T.self, from: reply.body)
    }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
