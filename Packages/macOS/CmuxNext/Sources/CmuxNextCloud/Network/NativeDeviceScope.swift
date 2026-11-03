public import Foundation

public enum NativeDeviceEnrollmentError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidScope, invalidState, busy, signedOut, revoked
    /// An identity or reply check refused, and where: the check's `file:line`, never a value.
    case invalidIdentity(at: String)
    /// An HTTP status the backend answered with, and the step that got it: an owner op name or a
    /// `METHOD /path` template with ids replaced (never an id or a token).
    case refused(Int, step: String)
    case secureStorage(Int32)

    public var description: String {
        switch self {
        case .invalidScope: "invalidScope"
        case .invalidState: "invalidState"
        case .invalidIdentity(let at): "invalidIdentity at \(at)"
        case .busy: "busy"
        case .signedOut: "signedOut"
        case .revoked: "revoked"
        case .refused(let status, let step): "refused(\(status)) at \(step)"
        case .secureStorage(let status): "secureStorage(\(status))"
        }
    }

    /// The identity refusal for the check at the call site.
    public static func identity(_ file: StaticString = #fileID, _ line: UInt = #line) -> Self {
        .invalidIdentity(at: "\(file):\(line)")
    }
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
    /// `METHOD /path` with device and mesh ids replaced by `{device}` and `{mesh}`, for error detail.
    static func step(_ method: String, _ path: String) -> String {
        let template = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            let value = String(segment)
            if isDevice(value) { return "{device}" }
            if isID(value, prefix: "mesh_") { return "{mesh}" }
            return value
        }.joined(separator: "/")
        return "\(method) \(template)"
    }
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
