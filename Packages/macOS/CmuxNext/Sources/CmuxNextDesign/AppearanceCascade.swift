public import CmuxNextDesignTokens
/// The values each appearance level sets, resolved most-specific-first with the source of each
/// (plans/cmux-next/appearance-scopes-DESIGN.md). Pure: owners build one from their stores and
/// read it on change events, never per frame.
///
/// ```swift
/// var cascade = AppearanceCascade(layers: [.workspace: [.tint: "blue"], .pane: [.tint: "red"]])
/// cascade.resolved(.tint)        // red, from pane
/// cascade.reset(.tint, at: .pane)
/// cascade.resolved(.tint)        // blue, from workspace
/// ```
public nonisolated struct AppearanceCascade: Equatable, Sendable {
    /// A resolved value and the level it came from.
    public struct Resolved: Equatable, Sendable {
        public var value: String
        public var source: AppearanceLevel
        public init(value: String, source: AppearanceLevel) {
            self.value = value
            self.source = source
        }
    }

    /// What each level sets.
    public private(set) var layers: [AppearanceLevel: [AppearanceProperty: String]]

    /// - Parameter layers: What each level sets; a missing level or property inherits.
    public init(layers: [AppearanceLevel: [AppearanceProperty: String]] = [:]) {
        self.layers = layers
    }

    /// The value in effect: the most specific level's.
    public func resolved(_ property: AppearanceProperty) -> Resolved? {
        resolve(property, levels: AppearanceLevel.allCases.reversed())
    }

    /// What `level` would show without its own value (what reset at `level` leads to).
    public func inherited(_ property: AppearanceProperty, below level: AppearanceLevel) -> Resolved? {
        resolve(property, levels: AppearanceLevel.allCases.filter { $0 < level }.reversed())
    }

    /// Sets `property` at `level`.
    public mutating func set(_ property: AppearanceProperty, _ value: String, at level: AppearanceLevel) {
        layers[level, default: [:]][property] = value
    }

    /// Removes `level`'s own value, so the level above shows again.
    public mutating func reset(_ property: AppearanceProperty, at level: AppearanceLevel) {
        layers[level]?[property] = nil
    }

    private func resolve(_ property: AppearanceProperty, levels: [AppearanceLevel]) -> Resolved? {
        for level in levels {
            if let value = layers[level]?[property] { return Resolved(value: value, source: level) }
        }
        return nil
    }
}
