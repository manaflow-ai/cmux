import Foundation

// Browser profile records (`browser-profiles-v1`, home session only;
// plans/cmux-next/data-model.md section 5). Every change emits
// `personal-changed`.

public struct BrowserProfileResult: Decodable, Sendable, Equatable {
    public var browserProfile: BrowserProfileSnapshot
    public var changed: Bool
    enum CodingKeys: String, CodingKey {
        case changed
        case browserProfile = "browser_profile"
    }
}

/// `create-browser-profile`: an existing id returns the stored record.
public struct CreateBrowserProfileRequest: DaemonRequest {
    public typealias Response = BrowserProfileResult
    public static let command = "create-browser-profile"
    public static let requiredCapability: String? = DaemonCapabilities.shared.browserProfiles
    public var id: String?
    public var name: String
    public var color: String?
    public var icon: String?
    public var index: Int?
    public var source: [String: String]?

    public init(id: String? = nil, name: String, color: String? = nil, icon: String? = nil, index: Int? = nil,
                source: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.index = index
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case name, color, icon, index, source
        case id = "browser_profile"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(index, forKey: .index)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

/// `update-browser-profile`: absent keeps, `.clear` sends null.
public struct UpdateBrowserProfileRequest: DaemonRequest {
    public typealias Response = BrowserProfileResult
    public static let command = "update-browser-profile"
    public static let requiredCapability: String? = DaemonCapabilities.shared.browserProfiles
    public var id: String
    public var name: String?
    public var color: FieldUpdate<String>
    public var icon: FieldUpdate<String>

    public init(id: String, name: String? = nil, color: FieldUpdate<String> = .unchanged, icon: FieldUpdate<String> = .unchanged) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey {
        case name, color, icon
        case id = "browser_profile"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(icon, forKey: .icon)
    }
}
