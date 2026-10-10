import AppKit

/// Why automation may not do something to a dialog (the USER-ONLY rule).
public nonisolated struct CmuxDialogAutomationRefusal: Error, Equatable, Sendable {
    public var dialog: Int
    public var kind: CmuxDialogConfirmKind
    /// The refused step: `press <button>`, `key <name>`, `set <field>`.
    public var step: String

    /// Stable text the debug socket reports (automation only, never UI).
    public var message: String {
        "dialog \(dialog) is a \(kind.rawValue) confirmation: only the user confirms it; automation may read, cancel or dismiss it (refused: \(step))"
    }
}

/// The one automation door into cmux dialogs (cx-zk9t). Every caller that is
/// not the person (the debug socket's `debug.dialog`, `debug.quit` and
/// `debug.extensions.prompt`, and any later socket, CLI, agent or extension
/// path) answers dialogs only through these methods. On a dialog whose
/// `confirmKind` is not `none` they allow reading, Escape, the cancel button
/// and dismissal, and refuse every other press, key and field change. The
/// person's own clicks and keys go through `CmuxDialogView` and `press`.
@MainActor
extension CmuxDialogCenter {
    /// The refusal for pressing `button` of dialog `id`, or nil when automation may.
    public func automationRefusal(_ id: Int, button: String) -> CmuxDialogAutomationRefusal? {
        guard let spec = record(id)?.spec, spec.confirmKind.isUserOnly else { return nil }
        if spec.buttons.first(where: { $0.id == button })?.role == .cancel { return nil }
        return CmuxDialogAutomationRefusal(dialog: id, kind: spec.confirmKind, step: "press \(button)")
    }

    /// Presses `button` for automation. Throws the refusal for a user-only
    /// confirm; false when there is no such dialog or button.
    @discardableResult
    public func automationPress(_ id: Int, button: String) throws(CmuxDialogAutomationRefusal) -> Bool {
        if let refusal = automationRefusal(id, button: button) { throw refusal }
        return press(id, button: button)
    }

    /// Runs one key for automation. A user-only dialog takes only keys that
    /// press its cancel button or move focus; typing and every other press
    /// are refused.
    @discardableResult
    public func automationKey(_ key: CmuxDialogKeys.Key, modifiers: CmuxDialogKeys.Modifiers = [], in id: Int,
                              name: String) throws(CmuxDialogAutomationRefusal) -> Bool {
        if let spec = record(id)?.spec, spec.confirmKind.isUserOnly {
            switch CmuxDialogKeys.action(for: key, modifiers: modifiers, in: spec) {
            case .focusNext?, .focusPrevious?: break
            case .press(let button)? where spec.buttons.first(where: { $0.id == button })?.role == .cancel: break
            default: throw CmuxDialogAutomationRefusal(dialog: id, kind: spec.confirmKind, step: "key \(name)")
            }
        }
        return self.key(key, modifiers: modifiers, in: id)
    }

    /// Sets a field for automation; refused on a user-only dialog (a field
    /// changes what the person's confirm would do).
    @discardableResult
    public func automationSetValue(_ value: CmuxDialogValue, for field: String,
                                   in id: Int) throws(CmuxDialogAutomationRefusal) -> Bool {
        if let kind = record(id)?.spec.confirmKind, kind.isUserOnly {
            throw CmuxDialogAutomationRefusal(dialog: id, kind: kind, step: "set \(field)")
        }
        return setValue(value, for: field, in: id)
    }

    /// Dismisses dialog `id` (its cancel answer). Always allowed: a refusal
    /// never needs the person.
    @discardableResult
    public func automationDismiss(_ id: Int) -> Bool { dismiss(id) }
}
