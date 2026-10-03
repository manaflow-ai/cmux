public import AppKit
public import CmuxNextActions

/// The palette's Cmd-K shortcut editor: the shared `ShortcutRecorder`
/// (CmuxNextActions, also used by the Settings window) with its state in
/// `PaletteModel.shortcutRecorder` and its notice on the edited row.
@MainActor public final class PaletteShortcutRecorder {
    public var registry: ActionRegistry { core.registry }
    public weak var editor: (any PaletteShortcutEditing)? {
        get { core.editor }
        set { core.editor = newValue }
    }
    private unowned let model: PaletteModel
    private let core: ShortcutRecorder

    init(registry: ActionRegistry, model: PaletteModel) {
        self.model = model
        core = ShortcutRecorder(
            registry: registry,
            state: { [unowned model] in model.shortcutRecorder },
            setState: { [unowned model] in model.shortcutRecorder = $0 },
            didFinish: { [unowned model] id, notice in
                model.reload()
                if let notice { model.showNotice(notice, on: id) }
            })
    }

    public var state: PaletteShortcutRecorderState? { model.shortcutRecorder }

    /// Opens the recorder for `id`. False when there is nothing to save to.
    @discardableResult
    public func begin(_ id: ActionID) -> Bool {
        guard editor != nil, registry.descriptor(for: id) != nil else { return false }
        model.closeActionsMenu()
        return core.begin(id)
    }

    /// A key-down while recording (see `ShortcutRecorder.handle`).
    @discardableResult
    public func handle(_ shortcut: Shortcut, keyCode: UInt16, event: NSEvent? = nil) -> Bool {
        core.handle(shortcut, keyCode: keyCode, event: event)
    }

    /// A click on an option, or the key for it.
    public func choose(_ option: PaletteShortcutOption) { core.choose(option) }

    /// Closes the recorder without a change (the palette hid), which also
    /// lets the system-wide hot keys register again.
    public func cancel() { core.cancel() }
}

extension PaletteShortcutRecorder {
    /// The recorder's view of a key-down (`ShortcutRecorder.shortcut(for:)`).
    public static func shortcut(for event: NSEvent) -> Shortcut { ShortcutRecorder.shortcut(for: event) }
}
