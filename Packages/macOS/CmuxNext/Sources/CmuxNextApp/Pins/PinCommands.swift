import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon

/// The one path every tab pin and unpin takes (PINNED-ITEMS-END-TO-END):
/// the palette, the tab menu, the CLI and MCP all run `palette.toggleTabPin`,
/// which calls this. The daemon owns the pin (`tab.pin` / `tab.unpin`); a
/// user's pin is also an undo step (P4, RECOVERABLE-BY-DEFAULT): Edit >
/// Undo Pin Tab sends the inverse op, and Redo sends it again. Automation
/// pins are not put on the user's undo stack.
@MainActor
struct PinCommands {
    let context: AppActionContext

    /// Pins or unpins the tab `id` (a daemon tab id), shown or not.
    func setTabPinned(_ id: String, pinned: Bool, origin: ActionOrigin) {
        guard apply(id, pinned: pinned) else { return }
        guard origin == .user else { return }
        registerUndo(title: pinned ? PinStrings.pinTab : PinStrings.unpinTab) { commands in
            commands.setTabPinned(id, pinned: !pinned, origin: .user)
        }
    }

    /// Sends the pin through the strip that shows the tab (its store
    /// intent), else straight to the daemon. False when the tab is gone.
    private func apply(_ id: String, pinned: Bool) -> Bool {
        guard let (tab, pane) = context.services.locateTab(id) ?? context.refuseQuietly(RefusalStrings.noTab(id)) else { return false }
        if let controller = context.services.paneController(for: pane) {
            controller.setPinned(StripTabID(id), pinned: pinned)
        } else {
            let surface = tab.surface
            context.send("set-tab-pinned") { _ = try await $0.setTabPinned(surface, pinned) }
        }
        return true
    }

    /// Registers `inverse` on the key window's undo manager.
    func registerUndo(title: String, _ inverse: @escaping @MainActor (PinCommands) -> Void) {
        guard let undoManager = NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager else { return }
        let record = PinUndoRecord { inverse(self) }
        // The record is the target and the retained object, so it lives as long as the undo entry.
        undoManager.registerUndo(withTarget: record, selector: #selector(PinUndoRecord.run(_:)), object: record)
        undoManager.setActionName(title)
    }
}

/// One pin's undo entry: runs the inverse, which registers the redo.
@MainActor
final class PinUndoRecord: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @objc func run(_ sender: Any?) {
        body()
    }
}
