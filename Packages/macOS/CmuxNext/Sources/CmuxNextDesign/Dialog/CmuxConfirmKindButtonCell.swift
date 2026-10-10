public import AppKit
import CmuxNextCompat

/// The cell of a button that carries a confirm kind (cx-zk9t). Accessibility clients see an
/// NSButton through its cell, so the cell publishes `AXCmuxConfirmKind` and refuses an
/// accessibility press of a user-only button unless an assistive technology runs
/// (`CmuxPersonInput`). An accepted press is a one-shot the button's action reads
/// (`takeAccessibilityPress`).
public final class CmuxConfirmKindButtonCell: NSButtonCell {
    private let kind = Mutex<CmuxDialogConfirmKind>(.none)
    private var acceptedPress = false

    /// What a press of the button grants.
    public var confirmKind: CmuxDialogConfirmKind {
        get { kind.withLock { $0 } }
        set { kind.withLock { $0 = newValue } }
    }

    public override func accessibilityPerformPress() -> Bool {
        guard confirmKind.isUserOnly else { return super.accessibilityPerformPress() }
        guard CmuxPersonInput.shared.acceptsAccessibilityPress() else { return false }
        acceptedPress = true
        defer { acceptedPress = false }
        return super.accessibilityPerformPress()
    }

    /// Whether the action now running comes from an accepted accessibility press; clears it.
    public func takeAccessibilityPress() -> Bool {
        defer { acceptedPress = false }
        return acceptedPress
    }

    @available(macOS, deprecated: 10.10, message: "custom accessibility attribute")
    nonisolated public override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [CmuxDialogConfirmKind.accessibilityAttribute]
    }

    @available(macOS, deprecated: 10.10, message: "custom accessibility attribute")
    nonisolated public override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        attribute == CmuxDialogConfirmKind.accessibilityAttribute ? kind.withLock { $0 }.rawValue : super.accessibilityAttributeValue(attribute)
    }
}
