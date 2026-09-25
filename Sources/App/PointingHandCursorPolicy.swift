import AppKit

/// Identifies native controls that should advertise clickability with the pointing-hand cursor.
struct PointingHandCursorPolicy {
    /// Returns whether an accessibility role represents a click target.
    static func shouldUsePointingHand(
        forRole role: NSAccessibility.Role?,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled, let role else { return false }
        return pointingHandRoleRawValues.contains(role.rawValue)
    }

    /// Returns whether a view or one of its ancestors is a native click target.
    static func shouldUsePointingHand(for view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            let isEnabled = (current as? NSControl)?.isEnabled ?? true
            if shouldUsePointingHand(forRole: current.accessibilityRole(), isEnabled: isEnabled) {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    private static let pointingHandRoleRawValues: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXLink",
        "AXMenuButton",
        "AXPopUpButton",
        "AXRadioButton",
        "AXTab",
    ]
}
