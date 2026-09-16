import Foundation

/// Selects where a saved resume command is allowed to execute.
enum SurfaceResumeLaunchFlavor: Equatable, Hashable, Sendable {
    case local
    case persistentSSH(SurfaceResumeRemoteContext)

    private enum CodingKeys: String, CodingKey {
        case kind
        case remoteContext
    }

    var executionLocationRawValue: String {
        switch self {
        case .local:
            return "local"
        case .persistentSSH:
            return "remote_ssh"
        }
    }

    var remoteContext: SurfaceResumeRemoteContext? {
        guard case .persistentSSH(let context) = self else { return nil }
        return context
    }

    /// Whether two bindings execute in the same local or persistent-SSH
    /// session, ignoring a persistent SSH owner's workspace/surface retarget.
    ///
    /// A moved remote surface receives a new owner context while its PTY
    /// session remains the same. Restore-state inheritance must follow that
    /// stable PTY identity, while local/remote transitions remain isolated.
    func representsSameExecutionLocation(as other: Self) -> Bool {
        switch (self, other) {
        case (.local, .local):
            return true
        case let (.persistentSSH(lhs), .persistentSSH(rhs)):
            guard let lhsSessionID = lhs.normalizedPersistentPTYSessionID,
                  let rhsSessionID = rhs.normalizedPersistentPTYSessionID else {
                return false
            }
            return lhsSessionID == rhsSessionID
        default:
            return false
        }
    }
}

extension SurfaceResumeLaunchFlavor: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "local":
            self = .local
        case "persistentSSH":
            self = .persistentSSH(
                try container.decode(SurfaceResumeRemoteContext.self, forKey: .remoteContext)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported surface resume launch flavor"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode("local", forKey: .kind)
        case .persistentSSH(let context):
            try container.encode("persistentSSH", forKey: .kind)
            try container.encode(context, forKey: .remoteContext)
        }
    }
}
