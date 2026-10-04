public import AppKit

/// Records a chord for one action and decides, with the registry's
/// `assessShortcut`, whether it is saved at once, asks first (a conflict
/// with another action, a browser chord, a Ghostty keybind) or is refused
/// (no Command or Control, a macOS chord, a system action's chord, a
/// numbered family). The palette's Cmd-K editor and the Settings window's
/// Keyboard section both run this one recorder; each keeps the state where
/// its view observes it (`state` / `setState`) and shows the notice
/// `didFinish` hands it. Every key-down while it records is consumed by the
/// owner, so none reaches a menu, a field or a terminal.
@MainActor public final class ShortcutRecorder {
    public let registry: ActionRegistry
    public weak var editor: (any ShortcutRecorderEditing)?
    private let readState: () -> ShortcutRecorderState?
    private let writeState: (ShortcutRecorderState?) -> Void
    private let didFinish: (ActionID, String?) -> Void

    /// `state`/`setState` read and write the owner's observable copy;
    /// `didFinish` runs once the recorder closed, with the notice to show
    /// (nil after Cancel).
    public init(registry: ActionRegistry,
                state: @escaping () -> ShortcutRecorderState?,
                setState: @escaping (ShortcutRecorderState?) -> Void,
                didFinish: @escaping (ActionID, String?) -> Void) {
        self.registry = registry
        self.readState = state
        self.writeState = setState
        self.didFinish = didFinish
    }

    public var state: ShortcutRecorderState? { readState() }

    /// Opens the recorder for `id`. False when there is nothing to save to.
    @discardableResult
    public func begin(_ id: ActionID) -> Bool {
        guard editor != nil, let descriptor = registry.descriptor(for: id) else { return false }
        writeState(ShortcutRecorderState(
            actionID: descriptor.id, actionTitle: descriptor.title, currentKeycaps: registry.shortcutKeycaps(for: descriptor.id),
            message: ShortcutRecorderStrings.recorderPrompt, hasDefault: descriptor.defaultShortcut != nil || descriptor.defaultChord != nil))
        setOpen(true)
        return true
    }

    /// Closes without a change.
    public func cancel() { finish(notice: nil) }

    /// A key-down while recording: `shortcut` is the chord with the base
    /// (unshifted) key, `keyCode` the physical key. Always consumed.
    @discardableResult
    public func handle(_ shortcut: Shortcut, keyCode: UInt16, event: NSEvent? = nil) -> Bool {
        guard var state = readState() else { return false }
        let bare = shortcut.modifiers.isEmpty
        switch keyCode {
        case 53 where bare:
            finish(notice: nil)
        case 51, 117:
            if bare { choose(.remove) } else if shortcut.modifiers == .shift { choose(.restoreDefault) } else { record(shortcut, event: event, into: &state) }
        case 36, 76 where state.pending != nil && (bare || shortcut.modifiers == .option):
            let pending = state.pending
            let primary: ShortcutRecorderOption = pending?.owners.isEmpty == true ? .save : (pending?.canReplace == true ? .replace : .keepBoth)
            choose(shortcut.modifiers == .option ? .keepBoth : primary)
        default:
            record(shortcut, event: event, into: &state)
        }
        return true
    }

    /// A click on an option, or the key for it.
    public func choose(_ option: ShortcutRecorderOption) {
        guard let state = readState() else { return }
        switch option {
        case .cancel:
            finish(notice: nil)
        case .remove:
            apply([ShortcutChange(state.actionID, nil)], notice: ShortcutRecorderStrings.shortcutRemoved)
        case .restoreDefault:
            restoreDefault(state)
        case .save, .replace, .keepBoth:
            guard let pending = state.pending else { return }
            if option == .keepBoth, !pending.canKeepBoth { return }
            if option == .replace, !pending.canReplace { return }
            let unbind = option == .keepBoth ? [] : pending.owners
            switch pending {
            case .set(let shortcut, _, _, _):
                let changes = [ShortcutChange(state.actionID, shortcut)] + unbind.map { ShortcutChange($0, nil) }
                apply(changes, notice: savedNotice(shortcut, removedFrom: unbind))
            case .restoreDefault:
                commitRestore(state.actionID, unbinding: unbind)
            }
        }
    }

    // MARK: Steps

    private func record(_ shortcut: Shortcut, event: NSEvent?, into state: inout ShortcutRecorderState) {
        state.recorded = shortcut
        state.pending = nil
        if registry.effectiveShortcut(for: state.actionID) == shortcut {
            return finish(notice: ShortcutRecorderStrings.shortcutUnchanged(shortcut.displayString))
        }
        let environment = editor?.environment(for: event) ?? ShortcutEditEnvironment()
        switch registry.assessShortcut(shortcut, for: state.actionID, environment: environment) {
        case .refused(let refusal):
            state.message = message(for: refusal, shortcut: shortcut, id: state.actionID)
        case .available(let notes) where notes.isEmpty:
            writeState(state)
            return apply([ShortcutChange(state.actionID, shortcut)], notice: savedNotice(shortcut, removedFrom: []))
        case .available(let notes):
            state.pending = .set(shortcut, owners: [], canKeepBoth: false)
            state.message = notes.map { self.note($0, shortcut: shortcut) }.joined(separator: " ")
        case .conflict(let owners, let canKeepBoth, let canReplace, let notes):
            state.pending = .set(shortcut, owners: owners, canKeepBoth: canKeepBoth, canReplace: canReplace)
            state.message = ([conflict(shortcut, owners: owners, canKeepBoth: canKeepBoth)] + notes.map { self.note($0, shortcut: shortcut) })
                .joined(separator: " ")
        }
        writeState(state)
    }

    private func restoreDefault(_ state: ShortcutRecorderState) {
        guard let shortcut = registry.descriptor(for: state.actionID)?.defaultShortcut else {
            return commitRestore(state.actionID, unbinding: [])
        }
        var state = state
        state.recorded = shortcut
        switch registry.assessShortcut(shortcut, for: state.actionID, environment: editor?.environment(for: nil) ?? ShortcutEditEnvironment()) {
        case .conflict(let owners, let canKeepBoth, let canReplace, _):
            state.pending = .restoreDefault(shortcut, owners: owners, canKeepBoth: canKeepBoth, canReplace: canReplace)
            state.message = conflict(shortcut, owners: owners, canKeepBoth: canKeepBoth)
            writeState(state)
        case .refused, .available:
            // A catalog default is valid by construction (the catalog tests).
            commitRestore(state.actionID, unbinding: [])
        }
    }

    private func commitRestore(_ id: ActionID, unbinding others: [ActionID]) {
        registry.removeShortcutOverride(for: id)
        for other in others { registry.setShortcutOverride(nil, for: other) }
        editor?.restoreDefault(id, unbinding: others)
        finish(notice: ShortcutRecorderStrings.defaultRestored)
    }

    /// Updates the registry at once (rows and menus change now; the file
    /// watcher confirms), then writes cmux.json.
    private func apply(_ changes: [ShortcutChange], notice: String) {
        for change in changes { registry.setShortcutOverride(change.shortcut, for: change.id) }
        editor?.save(changes)
        finish(notice: notice)
    }

    private func finish(notice: String?) {
        guard let state = readState() else { return }
        writeState(nil)
        setOpen(false)
        didFinish(state.actionID, notice)
    }

    /// The owner dropped the recorder's state itself (the palette hid or
    /// changed page): stop counting it as open, without a notice.
    public func abandon() { setOpen(false) }

    /// Counts this recorder among the open ones; `.recordingShortcut` holds
    /// while any is open, so the Settings and palette recorders can overlap.
    private func setOpen(_ open: Bool) {
        if open {
            registry.openShortcutRecorders.insert(ObjectIdentifier(self))
        } else {
            registry.openShortcutRecorders.remove(ObjectIdentifier(self))
        }
        if registry.openShortcutRecorders.isEmpty {
            registry.context.remove(.recordingShortcut)
        } else {
            registry.context.insert(.recordingShortcut)
        }
    }

    // MARK: Text

    private func title(_ id: ActionID) -> String {
        registry.descriptor(for: id)?.title ?? id.rawValue
    }

    private func titles(_ ids: [ActionID]) -> String {
        ListFormatter.localizedString(byJoining: ids.map(title))
    }

    private func savedNotice(_ shortcut: Shortcut, removedFrom owners: [ActionID]) -> String {
        owners.isEmpty ? ShortcutRecorderStrings.shortcutSaved(shortcut.displayString)
            : ShortcutRecorderStrings.shortcutSavedReplacing(shortcut.displayString, titles(owners))
    }

    private func conflict(_ shortcut: Shortcut, owners: [ActionID], canKeepBoth: Bool) -> String {
        let used = ShortcutRecorderStrings.shortcutUsedBy(shortcut.displayString, titles(owners))
        return canKeepBoth ? used + " " + ShortcutRecorderStrings.shortcutCanKeepBoth : used
    }

    private func message(for refusal: ShortcutRefusal, shortcut: Shortcut, id: ActionID) -> String {
        switch refusal {
        case .needsModifier: ShortcutRecorderStrings.shortcutNeedsModifier
        case .reservedByMacOS(let name): ShortcutRecorderStrings.shortcutReservedByMacOS(shortcut.displayString, name)
        case .systemAction(let owner): ShortcutRecorderStrings.shortcutOwnedBySystemAction(shortcut.displayString, title(owner))
        case .numberedFamily(let owner): ShortcutRecorderStrings.shortcutInNumberedFamily(shortcut.displayString, title(owner))
        case .editsNumberedFamily: ShortcutRecorderStrings.shortcutFamilyInConfig(id.rawValue)
        }
    }

    private func note(_ note: ShortcutNote, shortcut: Shortcut) -> String {
        switch note {
        case .chromeChord(let cmuxWins):
            cmuxWins ? ShortcutRecorderStrings.shortcutTakesChromeChord(shortcut.displayString)
                : ShortcutRecorderStrings.shortcutLeavesChromeChord(shortcut.displayString)
        case .ghosttyKeybind(let name):
            ShortcutRecorderStrings.shortcutBeatsGhostty(name)
        }
    }
}

extension ShortcutRecorder {
    /// The recorder's view of a key-down: the base key (Cmd-Shift-[ is `[`
    /// with Shift, as catalog shortcuts are written) and its modifiers.
    public static func shortcut(for event: NSEvent) -> Shortcut {
        let base = event.characters(byApplyingModifiers: [])?.lowercased()
        let key = base.flatMap { $0.isEmpty ? nil : $0 } ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        return Shortcut(key, modifiers: event.modifierFlags)
    }
}
