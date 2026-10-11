import Foundation

/// One browser profile record of the home session (`browser-profiles-v1`,
/// plans/cmux-next/data-model.md section 5). Wire shape
/// (`list-personal.browser_profiles[]`): `{id, name, color, icon, index,
/// source}`; `id` is `default` or a lowercase UUID.
public struct BrowserProfileSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    public var name: String
    public var color: String?
    public var icon: String?
    public var index: Int
    /// Import origin (`browser`, `profile_dir`, `display_name`), or nil.
    public var source: [String: String]?

    public init(id: String, name: String, color: String? = nil, icon: String? = nil, index: Int = 0, source: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.index = index
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, name, color, icon, index, source }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        // Only string members are kept; another shape is ignored.
        source = (try? c.decodeIfPresent([String: String].self, forKey: .source)) ?? nil
    }
}
