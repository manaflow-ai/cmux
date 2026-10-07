public import Foundation

/// Every native gallery entry. Each package that has views adds a registration method in an
/// extension (`GalleryRegistry.registerHome()` in CmuxNextHome) and the App's DEBUG gallery
/// calls each one once; entries can land before the gallery window does.
///
/// ```swift
/// extension GalleryRegistry {
///     public func registerHome() { register([HomeGallery.listRow, HomeGallery.bubble]) }
/// }
/// ```
@MainActor public final class GalleryRegistry {
    /// The App's registry.
    public static let shared = GalleryRegistry()

    private var byID: [String: GalleryEntry] = [:]
    private var order: [String] = []
    /// Entries refused at registration, and why (the gallery shows them; a test asserts none).
    public private(set) var problems: [String] = []

    public init() {}

    /// Adds `entries`. An entry with a bad id, no variants, a bad variant name or an id that is
    /// already registered is refused and recorded in ``problems``.
    public func register(_ entries: [GalleryEntry]) {
        for entry in entries {
            let refusal = Self.validate(entry) ?? (byID[entry.id] == nil ? nil : "\(entry.id): duplicate id")
            if let refusal {
                problems.append(refusal)
                continue
            }
            byID[entry.id] = entry
            order.append(entry.id)
        }
    }

    /// The entries, by area and then title.
    public var entries: [GalleryEntry] {
        order.compactMap { byID[$0] }.sorted { ($0.area, $0.title) < ($1.area, $1.title) }
    }

    public func entry(id: String) -> GalleryEntry? { byID[id] }

    /// The web format's rules (format.ts `validateEntries`): nil when `entry` is valid.
    public nonisolated static func validate(_ entry: GalleryEntry) -> String? {
        if !matches(entry.id, #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#) { return "\(entry.id): the id must be dotted lower kebab case" }
        if entry.variants.isEmpty { return "\(entry.id): no variants" }
        if let bad = entry.variants.first(where: { !matches($0.name, #"^[a-z0-9]+(-[a-z0-9]+)*$"#) }) {
            return "\(entry.id)#\(bad.name): variant names are lower kebab case"
        }
        if Set(entry.variants.map(\.name)).count != entry.variants.count { return "\(entry.id): duplicate variant names" }
        if entry.covers.isEmpty { return "\(entry.id): covers nothing" }
        return nil
    }

    private nonisolated static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
