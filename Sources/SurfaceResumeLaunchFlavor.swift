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
