import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign

/// Icon changes as undo steps (RECOVERABLE-BY-DEFAULT, the same as pins in
/// PINNED-ITEMS-END-TO-END P4): a user's set or remove on any object with an
/// icon (tab, workspace, workspace group, space, screen, browser profile)
/// offers its inverse as an undo toast (its Undo button and Cmd-Z run it,
/// which offers the next one). Automation (CLI, MCP, scripts, other
/// clients, pages) offers no undo.
@MainActor
struct IconHistory {
    /// The toast messages of a set and a remove.
    struct Messages {
        let set: String
        let remove: String

        /// "Icon Set" and "Icon Removed".
        static var icon: Self { Self(set: IconStrings.undoSet, remove: IconStrings.undoRemove) }
        /// "Tab Icon Set" and "Tab Icon Removed".
        static var tab: Self { Self(set: TabIconStrings.undoSet, remove: TabIconStrings.undoRemove) }
    }

    var messages = Messages.icon
    /// Sends one icon update for the object `id`. False when the object is
    /// gone; a throw (a missing daemon capability) reaches the caller.
    let apply: @MainActor (_ id: String, _ update: FieldUpdate<String>) throws -> Bool
    /// Offers one undo step: a toast with `message` whose Undo runs `undo`.
    let offerUndo: @MainActor (_ message: String, _ undo: @escaping @MainActor () -> Void) -> Void

    /// Changes the icon of object `id` from `previous` to `icon` (nil removes it).
    func change(_ id: String, from previous: String?, to icon: String?, origin: ActionOrigin) throws {
        guard try apply(id, icon.map { .set($0) } ?? .clear) else { return }
        guard origin == .user, previous != icon else { return }
        // The undo is the inverse change, which offers the redo the same way.
        offerUndo(icon == nil ? messages.remove : messages.set) { [self] in
            try? change(id, from: icon, to: previous, origin: .user)
        }
    }

    /// A history whose undo step goes on the active window's undo stack (the
    /// icon picker panel, key while it closes, is never its window). No
    /// toast: an icon change is not destructive; Edit > Undo and Cmd-Z undo it.
    static func inActiveWindow(_ ctx: AppActionContext, apply: @escaping @MainActor (String, FieldUpdate<String>) throws -> Bool) -> Self {
        IconHistory(apply: apply, offerUndo: { message, undo in
            guard let window = ctx.services.windows.active?.window ?? NSApp.mainWindow else { return }
            registerUndo(message, in: window, undo)
        })
    }

    /// Puts an icon change's inverse on `window`'s undo stack, titled `message`; no toast.
    static func registerUndo(_ message: String, in window: NSWindow, _ undo: @escaping @MainActor () -> Void) {
        ToastUndoStep.attach(title: message, filling: nil, undoManager: window.undoManager, handle: nil, undo)
    }
}

/// Undo toast messages of icon changes (Handlers.xcstrings).
enum IconStrings {
    static var undoSet: String { String(localized: "icon.undo.set", defaultValue: "Icon Set", table: "Handlers", bundle: .module) }
    static var undoRemove: String { String(localized: "icon.undo.remove", defaultValue: "Icon Removed", table: "Handlers", bundle: .module) }
}
