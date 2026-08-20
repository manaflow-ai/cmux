import Foundation

/// A named shortcut that expands an omnibar query into an HTTP(S) URL.
public struct BrowserSiteSearchShortcut: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var shortcut: String
    public var urlTemplate: String
    public var isActive: Bool

    /// Creates a site-search shortcut.
    public init(id: UUID = UUID(), name: String, shortcut: String, urlTemplate: String, isActive: Bool = true) {
        self.id = id; self.name = name; self.shortcut = shortcut; self.urlTemplate = urlTemplate; self.isActive = isActive
    }
    private enum CodingKeys: String, CodingKey { case id, name, shortcut, urlTemplate, isActive }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name); shortcut = try c.decode(String.self, forKey: .shortcut); urlTemplate = try c.decode(String.self, forKey: .urlTemplate)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
    /// Whether all required fields satisfy site-search constraints.
    public var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Self.isValidShortcut(shortcut) && Self.isValidURLTemplate(urlTemplate) }
    /// Builds a URL by percent-encoding the query and replacing `%s`.
    public func searchURL(query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !q.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=?#%")
        let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        return URL(string: urlTemplate.replacingOccurrences(of: "%s", with: encoded))
    }
    /// Validates a shortcut token.
    public static func isValidShortcut(_ value: String) -> Bool { let v = value.trimmingCharacters(in: .whitespacesAndNewlines); return !v.isEmpty && !v.contains(where: { $0.isWhitespace }) }
    /// Validates an HTTP(S) template containing `%s`.
    public static func isValidURLTemplate(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines); guard v.contains("%s"), let u = URL(string: v.replacingOccurrences(of: "%s", with: "test")), let s = u.scheme?.lowercased() else { return false }; return s == "http" || s == "https"
    }
}
