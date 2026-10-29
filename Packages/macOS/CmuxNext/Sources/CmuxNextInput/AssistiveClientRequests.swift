public import Foundation

/// What assistive clients asked of the app: VoiceOver sets `AXEnhancedUserInterface`, automation
/// drivers (cua) `AXManualAccessibility`, on the application element. The app wants Chromium's page
/// accessibility while either is on.
public nonisolated struct AssistiveClientRequests: Equatable, Sendable {
    public static let attributes: Set<String> = ["AXEnhancedUserInterface", "AXManualAccessibility"]
    private var values: [String: Bool] = [:]

    public init() {}

    public var wantsAccessibility: Bool { values.values.contains(true) }

    /// Records `value` for `attribute`; false (nothing recorded) for an attribute no assistive
    /// client sets.
    public mutating func set(_ value: Any?, for attribute: String) -> Bool {
        guard Self.attributes.contains(attribute) else { return false }
        values[attribute] = (value as? NSNumber)?.boolValue ?? false
        return true
    }

    /// What was set for `attribute`; nil for other attributes. Unset reads as false.
    public func value(for attribute: String) -> Bool? {
        Self.attributes.contains(attribute) ? values[attribute] ?? false : nil
    }
}
