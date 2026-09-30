import Foundation

/// A grouping of related ``DefaultsKey`` / ``JSONKey`` declarations.
///
/// `SettingCatalogSection` is the building block of ``SettingCatalog``. Every
/// section is a value-typed struct whose stored properties are setting keys
/// (or nested sections). Sections compose: ``SettingCatalog/all`` walks the
/// catalog with `Mirror`, descending into nested sections, and returns the
/// flat list of every key in declaration order.
///
/// Partition the catalog along the dotted-id prefix so the file scales to
/// hundreds of settings without becoming a wall of properties:
///
/// ```swift
/// public struct AppCatalogSection: SettingCatalogSection {
///     public let appearance = DefaultsKey<AppearanceMode>(
///         id: "app.appearance",
///         defaultValue: .system,
///         userDefaultsKey: "appearanceMode"
///     )
///     public init() {}
/// }
/// ```
///
/// A new section becomes a stored property on ``SettingCatalog``; reflection
/// in the default ``all`` implementation picks it up automatically.
public protocol SettingCatalogSection: Sendable {
    /// Every key declared by this section and any nested sections, flattened.
    var all: [AnySettingKey] { get }
}

extension SettingCatalogSection {
    /// Default implementation: walk `Mirror` over the receiver's stored
    /// properties, emit setting keys directly, and recurse into nested
    /// ``SettingCatalogSection`` values.
    public var all: [AnySettingKey] {
        Mirror(reflecting: self).children.flatMap { _, value -> [AnySettingKey] in
            if let key = value as? AnySettingKeyConvertible {
                return [key.asAnySettingKey]
            }
            if let section = value as? SettingCatalogSection {
                return section.all
            }
            return []
        }
    }
}
