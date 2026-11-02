import CryptoKit
public import Foundation
import os

/// Routing metadata verified by the original owner transport, not transport or serving authority.
public struct NativeNetworkTarget: Equatable, Sendable {
    public let scope: NativeDeviceScope
    public let origin: URL
    public let project: String
    public let ipv4CIDR: String

    init(_ reply: NativeNetworkTargetReply, team: String, mesh: String?, context: NativeInstallContext) throws {
        scope = try NativeDeviceScope(team: reply.team, tenant: reply.tenant, mesh: reply.mesh)
        guard reply.team == team, mesh == nil || mesh == reply.mesh,
              !reply.project.isEmpty, reply.project.utf8.count <= 128,
              reply.project.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }),
              context.user == "user_" + Self.digest("stack:\(reply.project):\(context.account)"),
              team == "team_" + Self.digest("stack-team:\(reply.project):\(reply.tenant)") || team == "team_" + Self.digest("personal:\(context.user)")
        else { throw NativeDeviceEnrollmentError.identity() }
        guard let supplied = URL(string: reply.origin) else { throw NativeDeviceEnrollmentError.invalidScope }
        origin = try NativeDeviceScope.canonicalOrigin(supplied)
        guard origin.absoluteString == reply.origin, Self.isMeshCIDR(reply.ipv4_cidr) else { throw NativeDeviceEnrollmentError.invalidScope }
        project = reply.project; ipv4CIDR = reply.ipv4_cidr
    }

    private static func digest(_ value: String) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
    }
    private static func isMeshCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "10", parts[3] == "0/20", let second = Int(parts[1]), let third = Int(parts[2]),
              (128...255).contains(second), (0...240).contains(third), third % 16 == 0 else { return false }
        return value == "10.\(second).\(third).0/20"
    }
}

extension MacInstallIdentity {
    /// Discover routing for an existing mesh using a fresh token for this team and the original owner transport.
    public func nativeNetworkTarget(team: String, mesh: String? = nil) async throws -> NativeNetworkTarget {
        // Validate caller selectors before token minting or any read.
        _ = try NativeDeviceScope(team: team, tenant: "selector", mesh: mesh ?? "mesh_" + String(repeating: "0", count: 26))
        let context = try await nativeContext(team: team)
        // The platform serves this read on its own route (cmux-platform NativeNetwork.ts), not as an op on
        // /v1/read: TeamDO answers that with "unknown read host.network.target". The mesh is a validated
        // NativeMeshId (above), so it needs no escaping.
        let reply = try await nativeOwnerGet(mesh.map { "/v1/host/network/target?mesh=\($0)" } ?? "/v1/host/network/target",
                                             context: context)
        guard reply.status == 200, reply.body.count <= 1_048_576 else {
            // validation.invalid here is a tenant with more than one mesh; selector.not_found is none.
            NativeNetworkRefusal.log("host.network.target", status: reply.status, body: reply.body)
            throw NativeDeviceEnrollmentError.refused(reply.status, step: "host.network.target")
        }
        let decoded = try JSONDecoder().decode(NativeNetworkTargetReply.self, from: reply.body)
        let target = try NativeNetworkTarget(decoded, team: team, mesh: mesh, context: context)
        try await nativeCheck(context)
        return target
    }
}

struct NativeNetworkTargetReply: Decodable, Sendable {
    let team: String
    let tenant: String
    let project: String
    let origin: String
    let mesh: String
    let ipv4_cidr: String
}
/// A Native refusal's stable code and message (server text, no credential), logged so a route that does not
/// start says why instead of a bare HTTP status.
struct NativeNetworkRefusal: Decodable {
    let code: String?
    let message: String?

    static func log(_ step: String, status: Int, body: Data) {
        let refusal = try? JSONDecoder().decode(Self.self, from: body.prefix(4096))
        log(step, status: status, code: refusal?.code, message: refusal?.message)
    }

    static func log(_ step: String, status: Int, code: String?, message: String?) {
        let code = code ?? "no code", message = String((message ?? "").prefix(300))
        Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.native")
            .error("\(step, privacy: .public) refused \(status): \(code, privacy: .public): \(message, privacy: .public)")
    }
}

/// An owner op's refusal body: `{"ok": false, "error": {"code", "message"}}`.
struct NativeOwnerRefusal: Decodable { let error: NativeNetworkRefusal? }
