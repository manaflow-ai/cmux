/// The notification payload carried through the notification-policy hook
/// pipeline: the workspace/surface the notification belongs to plus its
/// user-visible title, subtitle, and body. Encoded to a hook's stdin and
/// patched back from its stdout.
public struct TerminalNotificationPolicyPayload: Codable, Sendable, Equatable {
    public var workspaceId: String
    public var surfaceId: String?
    public var title: String
    public var subtitle: String
    public var body: String

    public init(
        workspaceId: String,
        surfaceId: String?,
        title: String,
        subtitle: String,
        body: String
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

/// Partial, hook-supplied overrides for ``TerminalNotificationPolicyPayload``.
/// Each field is optional so a hook may patch only the keys it cares about;
/// `surfaceId` is doubly optional so a hook can explicitly null it out.
struct TerminalNotificationPolicyPayloadPatch: Decodable {
    var workspaceId: String?
    var surfaceId: String??
    var title: String?
    var subtitle: String?
    var body: String?

    private enum CodingKeys: String, CodingKey {
        case workspaceId
        case surfaceId
        case title
        case subtitle
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try container.decodeIfNonNullValuePresent(String.self, forKey: .workspaceId)
        surfaceId = try container.decodeNullableValueIfPresent(String.self, forKey: .surfaceId)
        title = try container.decodeIfNonNullValuePresent(String.self, forKey: .title)
        subtitle = try container.decodeIfNonNullValuePresent(String.self, forKey: .subtitle)
        body = try container.decodeIfNonNullValuePresent(String.self, forKey: .body)
    }

    func merged(into payload: TerminalNotificationPolicyPayload) -> TerminalNotificationPolicyPayload {
        var merged = payload
        if let workspaceId {
            merged.workspaceId = workspaceId
        }
        if let surfaceId {
            merged.surfaceId = surfaceId
        }
        if let title {
            merged.title = title
        }
        if let subtitle {
            merged.subtitle = subtitle
        }
        if let body {
            merged.body = body
        }
        return merged
    }
}
