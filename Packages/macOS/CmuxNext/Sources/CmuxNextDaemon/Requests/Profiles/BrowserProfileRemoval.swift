import Foundation

// Moving and deleting browser profile records (`browser-profiles-v1`).

public struct MoveBrowserProfileRequest: DaemonRequest {
    public typealias Response = BrowserProfileResult
    public static let command = "move-browser-profile"
    public static let requiredCapability: String? = DaemonCapabilities.shared.browserProfiles
    public var id: String
    public var index: Int
    public init(id: String, index: Int) {
        self.id = id
        self.index = index
    }
    enum CodingKeys: String, CodingKey {
        case index
        case id = "browser_profile"
    }
}

/// `delete-browser-profile`: clears the workspace and room defaults naming it.
public struct DeleteBrowserProfileRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var clearedRooms: [String]
        enum CodingKeys: String, CodingKey { case clearedRooms = "cleared_rooms" }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clearedRooms = try c.decodeIfPresent([String].self, forKey: .clearedRooms) ?? []
        }
    }
    public static let command = "delete-browser-profile"
    public static let requiredCapability: String? = DaemonCapabilities.shared.browserProfiles
    public var id: String
    public init(id: String) {
        self.id = id
    }
    enum CodingKeys: String, CodingKey { case id = "browser_profile" }
}
