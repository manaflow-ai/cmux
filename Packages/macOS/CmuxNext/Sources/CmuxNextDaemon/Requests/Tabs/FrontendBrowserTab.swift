import Foundation

public enum BrowserEngine: String, Sendable, Hashable, Codable {
    case webkit, cef
}

/// Browser tab the app renders itself (`frontend-browser-tabs-v1`). The
/// daemon persists and restores it but never attaches or renders it.
public struct NewFrontendBrowserTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var tabResourceID: ResourceID?
        public var contentResourceID: ResourceID?
        enum CodingKeys: String, CodingKey {
            case surface
            case tabResourceID = "tab_resource_id"
            case contentResourceID = "content_resource_id"
        }
    }
    public static let command = "new-frontend-browser-tab"
    public static let requiredCapability: String? = DaemonCapabilities.shared.frontendBrowserTabs
    public var url: String
    public var engine: BrowserEngine
    public var pane: PaneID?
    public var title: String?
    public var faviconURL: String?
    public var profileID: String?
    public var cols: Int?
    public var rows: Int?
    /// `frontend-browser-activate-v1`: `false` keeps the pane's active tab (an automation's
    /// background tab); nil (omitted) makes the new tab active.
    public var activate: Bool?
    /// `frontend-browser-insert-after-v1`: the new tab goes right after this
    /// tab of the pane (a link's opener, or its last child) instead of at the end.
    public var after: SurfaceID?

    public init(url: String, engine: BrowserEngine, pane: PaneID? = nil, title: String? = nil, faviconURL: String? = nil,
                profileID: String? = nil, size: CellSize? = nil, activate: Bool? = nil, after: SurfaceID? = nil) {
        self.url = url
        self.engine = engine
        self.pane = pane
        self.title = title
        self.faviconURL = faviconURL
        self.profileID = profileID
        self.cols = size?.cols
        self.rows = size?.rows
        self.activate = activate
        self.after = after
    }
}

/// Records navigation of a frontend-rendered browser tab. Emits
/// `title-changed` (title) and `tab-changed`.
public struct UpdateFrontendBrowserTabRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var url: String
        public var title: String?
        public var faviconURL: String?
        public var changed: Bool
        enum CodingKeys: String, CodingKey {
            case surface, url, title, changed
            case faviconURL = "favicon_url"
        }
    }
    public static let command = "update-frontend-browser-tab"
    public static let requiredCapability: String? = DaemonCapabilities.shared.frontendBrowserTabs
    public var surface: SurfaceID
    public var url: String?
    public var title: String?
    public var faviconURL: FieldUpdate<String>

    public init(surface: SurfaceID, url: String? = nil, title: String? = nil, faviconURL: FieldUpdate<String> = .unchanged) {
        self.surface = surface
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
    }

    enum CodingKeys: String, CodingKey { case surface, url, title, faviconURL }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(faviconURL, forKey: .faviconURL)
    }
}
