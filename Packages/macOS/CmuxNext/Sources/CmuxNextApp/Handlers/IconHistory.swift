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

    /// A history whose undo toast shows in the active window (the icon
    /// picker panel, key while it closes, is never a toast's window).
    static func inActiveWindow(_ ctx: AppActionContext, apply: @escaping @MainActor (String, FieldUpdate<String>) throws -> Bool) -> Self {
        IconHistory(apply: apply, offerUndo: { message, undo in
            guard let window = ctx.services.windows?.active?.window ?? NSApp.mainWindow else { return }
            let handle = CmuxToastCenter.shared.show(CmuxToast(id: undoToastID, message: message, action: .undo()), in: window)
            handle.onAction = { undo() }
        })
    }

    /// The id of the icon undo toast (one per window; a newer change replaces it).
    static let undoToastID = "icon-undo"
}

/// Undo toast messages of icon changes (Handlers.xcstrings).
enum IconStrings {
    static var undoSet: String { String(localized: "icon.undo.set", defaultValue: "Icon Set", table: "Handlers", bundle: .module) }
    static var undoRemove: String { String(localized: "icon.undo.remove", defaultValue: "Icon Removed", table: "Handlers", bundle: .module) }
}

/// Undo toast messages of tab icon changes (Handlers.xcstrings).
enum TabIconStrings {
    static var undoSet: String { String(localized: "tabIcon.undo.set", defaultValue: "Tab Icon Set", table: "Handlers", bundle: .module) }
    static var undoRemove: String {
        String(localized: "tabIcon.undo.remove", defaultValue: "Tab Icon Removed", table: "Handlers", bundle: .module)
    }
}
