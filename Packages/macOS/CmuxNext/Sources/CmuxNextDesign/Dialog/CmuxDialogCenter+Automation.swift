public import AppKit

/// Why automation may not do something to a dialog (the USER-ONLY rule).
public nonisolated struct CmuxDialogAutomationRefusal: Error, Equatable, Sendable {
    public var dialog: Int
    public var kind: CmuxDialogConfirmKind
    /// The refused step: `press <button>`, `key <name>`, `set <field>`.
    public var step: String

    public init(dialog: Int, kind: CmuxDialogConfirmKind, step: String) {
        self.dialog = dialog
        self.kind = kind
        self.step = step
    }

    /// Stable text the debug socket reports (automation only, never UI).
    public var message: String {
        "dialog \(dialog): only the user may confirm a \(kind.rawValue) choice; automation may read the dialog, cancel or dismiss it (refused: \(step))"
    }
}

/// The one automation door into cmux dialogs (cx-zk9t). Every caller that is
/// not the person (the debug socket's `debug.dialog`, `debug.quit` and
/// `debug.extensions.prompt`, and any later socket, CLI, agent or extension
/// path) answers dialogs only through these methods. The rule is per button
/// (`CmuxDialogSpec.confirmKind(of:)`): automation may read every dialog,
/// press a button whose kind is `none` (a cancel button always is), and
/// dismiss; it may never press a money, destructive, consent or trust button,
/// by press or by key. While a dialog has such a button
/// (`CmuxDialogSpec.userOnlyKind`), its fields and typing answer only to the
/// person, since a field changes what the person's confirm does. The person's
/// own clicks and keys go through `CmuxDialogView` and `press`.
@MainActor
extension CmuxDialogCenter {
    /// The refusal for pressing `button` of dialog `id`, or nil when automation may
    /// (also nil for an unknown dialog or button: the press then does nothing).
    public func automationRefusal(_ id: Int, button: String) -> CmuxDialogAutomationRefusal? {
        guard let spec = record(id)?.spec, let pressed = spec.buttons.first(where: { $0.id == button }) else { return nil }
        let kind = spec.confirmKind(of: pressed)
        return kind.isUserOnly ? CmuxDialogAutomationRefusal(dialog: id, kind: kind, step: "press \(button)") : nil
    }

    /// Presses `button` for automation. Throws the refusal for a user-only
    /// button; false when there is no such dialog or button.
    @discardableResult
    public func automationPress(_ id: Int, button: String) throws(CmuxDialogAutomationRefusal) -> Bool {
        if let refusal = automationRefusal(id, button: button) { throw refusal }
        return press(id, button: button)
    }

    /// Runs one key for automation. A key that presses a button follows that
    /// button's kind; focus keys always pass; typing passes only while the
    /// dialog has no user-only button.
    @discardableResult
    public func automationKey(_ key: CmuxDialogKeys.Key, modifiers: CmuxDialogKeys.Modifiers = [], in id: Int,
                              name: String) throws(CmuxDialogAutomationRefusal) -> Bool {
        if let spec = record(id)?.spec {
            switch CmuxDialogKeys.action(for: key, modifiers: modifiers, in: spec) {
            case .focusNext?, .focusPrevious?: break
            case .press(let button)?:
                if let refusal = automationRefusal(id, button: button) {
                    throw CmuxDialogAutomationRefusal(dialog: id, kind: refusal.kind, step: "key \(name)")
                }
            case nil:
                if spec.userOnlyKind.isUserOnly {
                    throw CmuxDialogAutomationRefusal(dialog: id, kind: spec.userOnlyKind, step: "key \(name)")
                }
            }
        }
        return self.key(key, modifiers: modifiers, in: id)
    }

    /// Sets a field for automation; refused while the dialog has a user-only
    /// button (a field changes what the person's confirm would do).
    @discardableResult
    public func automationSetValue(_ value: CmuxDialogValue, for field: String,
                                   in id: Int) throws(CmuxDialogAutomationRefusal) -> Bool {
        if let kind = record(id)?.spec.userOnlyKind, kind.isUserOnly {
            throw CmuxDialogAutomationRefusal(dialog: id, kind: kind, step: "set \(field)")
        }
        return setValue(value, for: field, in: id)
    }

    /// A visible dialog with a user-only button over `window` (its overlay panel, or an
    /// app-wide dialog), else nil. Input-posting automation (`debug.key`, `debug.mouse`)
    /// refuses while one shows, so posted keys and clicks cannot answer it.
    public func visibleUserOnlyDialog(over window: NSWindow?) -> Record? {
        records.first { record in
            guard record.visible, record.spec.userOnlyKind.isUserOnly else { return false }
            guard let window, let shown = view(record.id)?.window else { return true }
            return shown === window || shown.parent === window || record.scope == "app"
        }
    }

    /// The refusal `visibleUserOnlyDialog(over:)` gives an input-posting step.
    public func inputRefusal(over window: NSWindow?, step: String) -> CmuxDialogAutomationRefusal? {
        visibleUserOnlyDialog(over: window).map { CmuxDialogAutomationRefusal(dialog: $0.id, kind: $0.spec.userOnlyKind, step: step) }
    }

    /// Dismisses dialog `id` (its cancel answer). Always allowed: a refusal
    /// never needs the person.
    @discardableResult
    public func automationDismiss(_ id: Int) -> Bool { dismiss(id) }
}
