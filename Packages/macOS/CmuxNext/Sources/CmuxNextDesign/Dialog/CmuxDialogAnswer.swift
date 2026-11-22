import Foundation

/// The one answer a dialog reports: the button pressed and every field's value.
public nonisolated struct CmuxDialogAnswer: Equatable, Sendable {
    public var button: String
    public var role: CmuxDialogButton.Role
    public var values: [String: CmuxDialogValue]
    /// True when nobody pressed a button: the scope closed, the app quit,
    /// or the owner withdrew the question (`CmuxDialogCenter.dismiss`).
    public var isDismissal: Bool

    public init(button: String, role: CmuxDialogButton.Role, values: [String: CmuxDialogValue] = [:], isDismissal: Bool = false) {
        self.button = button
        self.role = role
        self.values = values
        self.isDismissal = isDismissal
    }

    public var isCancel: Bool { role == .cancel }
    public func text(_ field: String) -> String? { values[field]?.text }
    public func isOn(_ field: String) -> Bool { values[field]?.bool ?? false }

    /// The answer when a dialog ends without a press (its tab closed, the
    /// app quits): the cancel button, else a synthetic "cancel".
    static func dismissed(_ spec: CmuxDialogSpec, values: [String: CmuxDialogValue]) -> CmuxDialogAnswer {
        let cancel = spec.cancelButton
        return CmuxDialogAnswer(button: cancel?.id ?? "cancel", role: cancel?.role ?? .cancel, values: values, isDismissal: true)
    }
}
