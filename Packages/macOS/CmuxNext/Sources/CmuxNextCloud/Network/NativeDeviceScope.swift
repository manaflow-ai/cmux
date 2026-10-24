public import Foundation

public enum NativeDeviceEnrollmentError: Error, Equatable, Sendable {
    case invalidScope, invalidState, invalidIdentity, busy, signedOut, revoked
    case refused(Int)
    case secureStorage(Int32)
}

/// Explicit backend team and Native tenant/mesh. No endpoint or credential comes from enrollment replies.
public struct NativeDeviceScope: Encodable, Hashable, Sendable {
    public let team: String
    public let tenant: String
    public let mesh: String

    public init(team: String, tenant: String, mesh: String) throws {
        guard team.utf8.count == 25, team.hasPrefix("team_"), team.dropFirst(5).allSatisfy({ "0123456789abcdef".contains($0) }),
              !tenant.isEmpty, tenant.utf8.count <= 128, tenant.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              Self.isID(mesh, prefix: "mesh_") else { throw NativeDeviceEnrollmentError.invalidScope }
        self.team = team; self.tenant = tenant; self.mesh = mesh
    }

    static func isDevice(_ value: String) -> Bool { isID(value, prefix: "dev_") }
    static func canonicalOrigin(_ origin: URL) throws -> URL {
        guard var c = URLComponents(url: origin, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { throw NativeDeviceEnrollmentError.invalidScope }
        c.scheme = "https"; c.host = c.host?.lowercased(); c.path = ""
        if c.port == 443 { c.port = nil }
        guard let result = c.url else { throw NativeDeviceEnrollmentError.invalidScope }
        return result
    }
    private static func isID(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.utf8.count == prefix.utf8.count + 26 && value.dropFirst(prefix.count).allSatisfy { "0123456789abcdefghjkmnpqrstvwxyz".contains($0) }
    }
}

/// Historical identity confirmation. Receiving policy and transport authorization remain separate.
public struct NativeDeviceBinding: Equatable, Sendable {
    public let host: String
    public let team: String
    public let tenant: String
    public let mesh: String
    public let device: String
    public let wgPublicKey: String
}
