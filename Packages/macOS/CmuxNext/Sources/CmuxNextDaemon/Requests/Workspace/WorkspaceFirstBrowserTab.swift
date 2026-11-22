import Foundation

/// The first tab of a new workspace, made by the same `create-workspace` request
/// (`workspace-first-tab-v1`): a browser tab the app renders. The daemon makes the workspace and
/// the tab together, so no client ever sees the workspace empty or with a terminal in the tab's
/// place, and a tab it cannot make takes the workspace back.
public struct WorkspaceFirstBrowserTab: Sendable, Equatable, Encodable {
    public var url: String
    public var engine: BrowserEngine
    public var title: String?
    public var profileID: String?
    /// One key for every send of the create: a request repeated after a late reply answers the
    /// tab the first one made (`frontend-browser-tab-keys-v1`).
    public var idempotencyKey: String

    public init(url: String, engine: BrowserEngine, title: String? = nil, profileID: String? = nil,
                idempotencyKey: String? = nil) {
        self.url = url
        self.engine = engine
        self.title = title
        self.profileID = profileID
        self.idempotencyKey = idempotencyKey ?? UUID().uuidString
    }

    enum CodingKeys: String, CodingKey {
        case kind, url, engine, title
        case profileID = "profile_id"
        case idempotencyKey = "idempotency_key"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("browser", forKey: .kind)
        try c.encode(url, forKey: .url)
        try c.encode(engine, forKey: .engine)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(profileID, forKey: .profileID)
        try c.encode(idempotencyKey, forKey: .idempotencyKey)
    }
}
