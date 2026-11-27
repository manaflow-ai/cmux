internal import Foundation

/// What assistive clients asked of the app: VoiceOver sets `AXEnhancedUserInterface`, automation
/// drivers (cua) `AXManualAccessibility`, on the application element. The app wants Chromium's page
/// accessibility while either is on, or for the whole run when the app was launched with
/// `CMUX_NEXT_ACCESSIBILITY=1` (a driver whose process holds no Accessibility grant of its own, so
/// it cannot set either attribute: the GUI probes' runner, refused with kAXErrorAPIDisabled).
public nonisolated struct AssistiveClientRequests: Equatable {
    /// The attributes assistive clients set on the application element.
    public static let attributes: Set<String> = ["AXEnhancedUserInterface", "AXManualAccessibility"]
    /// The launch environment's switch for a run that always wants the page tree.
    public static let environmentKey = "CMUX_NEXT_ACCESSIBILITY"
    private var values: [String: Bool] = [:]
    /// On for the whole run, whatever the attributes say.
    public let forced: Bool

    /// No attribute set; `forced` when the launch asked for the tree from the start.
    public init(forced: Bool = false) { self.forced = forced }

    /// Forced when `environment` has `CMUX_NEXT_ACCESSIBILITY=1`.
    public init(environment: [String: String]) { self.init(forced: environment[Self.environmentKey] == "1") }

    /// Whether the run is forced on or either attribute is on.
    public var wantsAccessibility: Bool { forced || values.values.contains(true) }

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
