import CryptoKit
public import Foundation

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
        else { throw NativeDeviceEnrollmentError.invalidIdentity }
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
        let body = try JSONEncoder().encode(NativeNetworkTargetCall(params: .init(mesh: mesh)))
        let reply = try await nativeOwnerRead(body, context: context)
        guard reply.status == 200, reply.body.count <= 1_048_576 else { throw NativeDeviceEnrollmentError.refused(reply.status) }
        let decoded = try JSONDecoder().decode(NativeNetworkTargetEnvelope.self, from: reply.body)
        guard decoded.op == "host.network.target" else { throw NativeDeviceEnrollmentError.invalidIdentity }
        let target = try NativeNetworkTarget(decoded.value, team: team, mesh: mesh, context: context)
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
private struct NativeNetworkTargetEnvelope: Decodable { let op: String; let value: NativeNetworkTargetReply }
private struct NativeNetworkTargetParams: Encodable { let mesh: String? }
private struct NativeNetworkTargetCall: Encodable { let op = "host.network.target"; let params: NativeNetworkTargetParams }
