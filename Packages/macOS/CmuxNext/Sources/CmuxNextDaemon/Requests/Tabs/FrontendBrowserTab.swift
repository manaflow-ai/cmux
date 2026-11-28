import Foundation

public enum BrowserEngine: String, Sendable, Hashable, Codable {
    case webkit, cef
}

/// `new-frontend-browser-tab` (generated, swift_app bindings.json): what the daemon answers.
extension NewFrontendBrowserTabRequest {
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
}

/// Records navigation of a frontend-rendered browser tab. Emits
/// `title-changed` (title) and `tab-changed`.
extension UpdateFrontendBrowserTabRequest {
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
}

/// Moves a frontend-rendered browser tab to another browser profile in place
/// (`frontend-browser-tab-profile-v1`): the tab keeps its surface, id and
/// position; `tab-changed` carries the new `browser_profile_id`.
public struct SetFrontendBrowserTabProfileRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var profileID: String?
        public var changed: Bool
        enum CodingKeys: String, CodingKey {
            case surface, changed
            case profileID = "profile_id"
        }
    }
    public static let command = "update-frontend-browser-tab"
    public static let requiredCapability: String? = DaemonCapability.frontendBrowserTabProfile.rawValue
    public var surface: SurfaceID
    /// `default` or a lowercase UUID.
    public var profileID: String

    public init(surface: SurfaceID, profileID: String) {
        self.surface = surface
        self.profileID = profileID
    }

    enum CodingKeys: String, CodingKey {
        case surface
        case profileID = "profile_id"
    }
}
