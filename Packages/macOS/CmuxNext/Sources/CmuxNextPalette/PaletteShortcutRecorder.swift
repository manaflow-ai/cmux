public import AppKit
public import CmuxNextActions

/// What the shortcut recorder needs from the App: the chord's other
/// meanings, and writing `shortcuts.bindings` in cmux.json (the file
/// watcher then applies it to every window).
@MainActor public protocol PaletteShortcutEditing: AnyObject {
    /// Ghostty keybinds and Chrome chords for the key-down being recorded
    /// (nil for a restored default).
    func environment(for event: NSEvent?) -> ShortcutEditEnvironment
    /// Writes each shortcut; nil unbinds the action (`null`).
    func save(_ changes: [ShortcutChange])
    /// Removes `id`'s override, restoring its default, and unbinds `others`.
    func restoreDefault(_ id: ActionID, unbinding others: [ActionID])
}

public struct ShortcutChange: Equatable, Sendable {
    public var id: ActionID
    public var shortcut: Shortcut?

    public init(_ id: ActionID, _ shortcut: Shortcut?) {
        self.id = id
        self.shortcut = shortcut
    }
}

/// A chord waiting for the user's choice (a conflict, or a note to read).
public enum PaletteShortcutPending: Equatable, Sendable {
    case set(Shortcut, owners: [ActionID], canKeepBoth: Bool, canReplace: Bool = true)
    case restoreDefault(Shortcut, owners: [ActionID], canKeepBoth: Bool, canReplace: Bool = true)

    var owners: [ActionID] {
        switch self {
        case .set(_, let owners, _, _), .restoreDefault(_, let owners, _, _): owners
        }
    }

    var canKeepBoth: Bool {
        switch self {
        case .set(_, let owners, let keep, _), .restoreDefault(_, let owners, let keep, _): keep && !owners.isEmpty
        }
    }

    var canReplace: Bool {
        switch self {
        case .set(_, _, _, let replace), .restoreDefault(_, _, _, let replace): replace
        }
    }
}

/// The inline recorder's state, shown over the palette (Cmd-K on an action).
public struct PaletteShortcutRecorderState: Equatable, Sendable {
    public let actionID: ActionID
    public let actionTitle: String
    /// The action's shortcut before this edit.
    public var currentKeycaps: [String]?
    /// The last chord pressed.
    public var recorded: Shortcut?
    /// Why the chord was refused, what it collides with, or a note.
    public var message: String?
    public var pending: PaletteShortcutPending?
    public var hasDefault: Bool

    /// The choices the recorder offers now, in order.
    public var options: [PaletteShortcutOption] {
        guard let pending else { return [.cancel, .remove, .restoreDefault] }
        var options: [PaletteShortcutOption] = []
        if pending.owners.isEmpty { options.append(.save) } else if pending.canReplace { options.append(.replace) }
        if pending.canKeepBoth { options.append(.keepBoth) }
        options.append(.cancel)
        return options
    }
}

public enum PaletteShortcutOption: Equatable, Sendable {
    case save, replace, keepBoth, cancel, remove, restoreDefault
}

/// Records a chord for one action and decides, with the registry's
/// `assessShortcut`, whether it is saved at once, asks first (a conflict
/// with another action, a Chrome chord, a Ghostty keybind) or is refused
/// (no Command or Control, a macOS chord, a system action's chord, a
/// numbered family). Every key-down while it is open is consumed, so none
/// reaches a menu, the field or a terminal.
@MainActor public final class PaletteShortcutRecorder {
    public let registry: ActionRegistry
    public weak var editor: (any PaletteShortcutEditing)?
    private unowned let model: PaletteModel

    init(registry: ActionRegistry, model: PaletteModel) {
        self.registry = registry
        self.model = model
    }

    public var state: PaletteShortcutRecorderState? { model.shortcutRecorder }

    /// Opens the recorder for `id`. False when there is nothing to save to.
    @discardableResult
    public func begin(_ id: ActionID) -> Bool {
        guard editor != nil, let descriptor = registry.descriptor(for: id) else { return false }
        model.closeActionsMenu()
        model.shortcutRecorder = PaletteShortcutRecorderState(
            actionID: descriptor.id, actionTitle: descriptor.title, currentKeycaps: registry.shortcutKeycaps(for: descriptor.id),
            message: PaletteStrings.recorderPrompt, hasDefault: descriptor.defaultShortcut != nil)
        return true
    }

    /// A key-down while recording: `shortcut` is the chord with the base
    /// (unshifted) key, `keyCode` the physical key. Always consumed.
    @discardableResult
    public func handle(_ shortcut: Shortcut, keyCode: UInt16, event: NSEvent? = nil) -> Bool {
        guard var state = model.shortcutRecorder else { return false }
        let bare = shortcut.modifiers.isEmpty
        switch keyCode {
        case 53 where bare:
            finish(notice: nil)
        case 51, 117:
            if bare { choose(.remove) } else if shortcut.modifiers == .shift { choose(.restoreDefault) } else { record(shortcut, event: event, into: &state) }
        case 36, 76 where state.pending != nil && (bare || shortcut.modifiers == .option):
            let pending = state.pending
            let primary: PaletteShortcutOption = pending?.owners.isEmpty == true ? .save : (pending?.canReplace == true ? .replace : .keepBoth)
            choose(shortcut.modifiers == .option ? .keepBoth : primary)
        default:
            record(shortcut, event: event, into: &state)
        }
        return true
    }

    /// A click on an option, or the key for it.
    public func choose(_ option: PaletteShortcutOption) {
        guard let state = model.shortcutRecorder else { return }
        switch option {
        case .cancel:
            finish(notice: nil)
        case .remove:
            apply([ShortcutChange(state.actionID, nil)], notice: PaletteStrings.shortcutRemoved)
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

    private func record(_ shortcut: Shortcut, event: NSEvent?, into state: inout PaletteShortcutRecorderState) {
        state.recorded = shortcut
        state.pending = nil
        if registry.effectiveShortcut(for: state.actionID) == shortcut {
            return finish(notice: PaletteStrings.shortcutUnchanged(shortcut.displayString))
        }
        let environment = editor?.environment(for: event) ?? ShortcutEditEnvironment()
        switch registry.assessShortcut(shortcut, for: state.actionID, environment: environment) {
        case .refused(let refusal):
            state.message = message(for: refusal, shortcut: shortcut)
        case .available(let notes) where notes.isEmpty:
            model.shortcutRecorder = state
            return apply([ShortcutChange(state.actionID, shortcut)], notice: savedNotice(shortcut, removedFrom: []))
        case .available(let notes):
            state.pending = .set(shortcut, owners: [], canKeepBoth: false)
            state.message = notes.map { self.note($0, shortcut: shortcut) }.joined(separator: " ")
        case .conflict(let owners, let canKeepBoth, let canReplace, let notes):
            state.pending = .set(shortcut, owners: owners, canKeepBoth: canKeepBoth, canReplace: canReplace)
            state.message = ([conflict(shortcut, owners: owners, canKeepBoth: canKeepBoth)] + notes.map { self.note($0, shortcut: shortcut) })
                .joined(separator: " ")
        }
        model.shortcutRecorder = state
    }

    private func restoreDefault(_ state: PaletteShortcutRecorderState) {
        guard let shortcut = registry.descriptor(for: state.actionID)?.defaultShortcut else {
            return commitRestore(state.actionID, unbinding: [])
        }
        var state = state
        state.recorded = shortcut
        switch registry.assessShortcut(shortcut, for: state.actionID, environment: editor?.environment(for: nil) ?? ShortcutEditEnvironment()) {
        case .conflict(let owners, let canKeepBoth, let canReplace, _):
            state.pending = .restoreDefault(shortcut, owners: owners, canKeepBoth: canKeepBoth, canReplace: canReplace)
            state.message = conflict(shortcut, owners: owners, canKeepBoth: canKeepBoth)
            model.shortcutRecorder = state
        case .refused, .available:
            // A catalog default is valid by construction (the catalog tests).
            commitRestore(state.actionID, unbinding: [])
        }
    }

    private func commitRestore(_ id: ActionID, unbinding others: [ActionID]) {
        registry.removeShortcutOverride(for: id)
        for other in others { registry.setShortcutOverride(nil, for: other) }
        editor?.restoreDefault(id, unbinding: others)
        finish(notice: PaletteStrings.defaultRestored)
    }

    /// Updates the registry at once (the row and menus change now; the
    /// file watcher confirms), then writes cmux.json.
    private func apply(_ changes: [ShortcutChange], notice: String) {
        for change in changes { registry.setShortcutOverride(change.shortcut, for: change.id) }
        editor?.save(changes)
        finish(notice: notice)
    }

    private func finish(notice: String?) {
        guard let state = model.shortcutRecorder else { return }
        model.shortcutRecorder = nil
        model.reload()
        if let notice { model.showNotice(notice, on: state.actionID) }
    }

    // MARK: Text

    private func title(_ id: ActionID) -> String {
        registry.descriptor(for: id)?.title ?? id.rawValue
    }

    private func titles(_ ids: [ActionID]) -> String {
        ListFormatter.localizedString(byJoining: ids.map(title))
    }

    private func savedNotice(_ shortcut: Shortcut, removedFrom owners: [ActionID]) -> String {
        owners.isEmpty ? PaletteStrings.shortcutSaved(shortcut.displayString)
            : PaletteStrings.shortcutSavedReplacing(shortcut.displayString, titles(owners))
    }

    private func conflict(_ shortcut: Shortcut, owners: [ActionID], canKeepBoth: Bool) -> String {
        let used = PaletteStrings.shortcutUsedBy(shortcut.displayString, titles(owners))
        return canKeepBoth ? used + " " + PaletteStrings.shortcutCanKeepBoth : used
    }

    private func message(for refusal: ShortcutRefusal, shortcut: Shortcut) -> String {
        switch refusal {
        case .needsModifier: PaletteStrings.shortcutNeedsModifier
        case .reservedByMacOS(let name): PaletteStrings.shortcutReservedByMacOS(shortcut.displayString, name)
        case .systemAction(let owner): PaletteStrings.shortcutOwnedBySystemAction(shortcut.displayString, title(owner))
        case .numberedFamily(let owner): PaletteStrings.shortcutInNumberedFamily(shortcut.displayString, title(owner))
        case .editsNumberedFamily: PaletteStrings.shortcutFamilyInConfig(model.shortcutRecorder?.actionID.rawValue ?? "")
        }
    }

    private func note(_ note: ShortcutNote, shortcut: Shortcut) -> String {
        switch note {
        case .chromeChord(let cmuxWins):
            cmuxWins ? PaletteStrings.shortcutTakesChromeChord(shortcut.displayString) : PaletteStrings.shortcutLeavesChromeChord(shortcut.displayString)
        case .ghosttyKeybind(let name):
            PaletteStrings.shortcutBeatsGhostty(name)
        }
    }
}

extension PaletteShortcutRecorder {
    /// The recorder's view of a key-down: the base key (Cmd-Shift-[ is `[`
    /// with Shift, as catalog shortcuts are written) and its modifiers.
    public static func shortcut(for event: NSEvent) -> Shortcut {
        let base = event.characters(byApplyingModifiers: [])?.lowercased()
        let key = base.flatMap { $0.isEmpty ? nil : $0 } ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        return Shortcut(key, modifiers: event.modifierFlags)
    }
}
