public import AppKit

/// What a confirm in a dialog grants (the USER-ONLY rule, cx-zk9t). A dialog
/// that spends money, destroys something, takes consent, or grants a
/// permission or trust answers only to the person: every automation path
/// (the debug socket, the CLI, agent tools, extensions, our computer-use
/// drivers) may read it and cancel or dismiss it, never confirm it. The one
/// check is `CmuxDialogCenter.automationRefusal`; the kind is published to
/// accessibility clients as ``accessibilityAttribute``.
public nonisolated enum CmuxDialogConfirmKind: String, Sendable, CaseIterable {
    /// Automation may answer it like a person (a rename, a page `alert`).
    case none
    /// A confirm spends money (a Cloud machine create, a paid option).
    case money
    /// A confirm deletes, ends or overwrites something.
    case destructive
    /// A confirm hands over the person's data or acts in their name
    /// (clipboard, credentials, a file outside the project).
    case consent
    /// A confirm grants a permission or trust (an extension, a program, a
    /// security setting, an app's scopes).
    case trust

    /// Only the person may confirm a dialog of this kind.
    public var isUserOnly: Bool { self != .none }

    /// The accessibility attribute that carries the kind on the dialog view
    /// and on each of its buttons (`AXCmuxConfirmKind`, value: the raw kind).
    /// Our computer-use drivers read it and refuse a non-cancel press when
    /// the kind is not `none`.
    public static let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXCmuxConfirmKind")
}
