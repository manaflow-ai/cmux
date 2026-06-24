public import Foundation
public import SwiftUI

/// Pure decision predicates for running and dismissing command-palette
/// commands and for the rename-input keystroke flow.
///
/// These are window-state-free rules evaluated while handling a palette command
/// or keystroke: whether to dismiss the overlay before running a command,
/// whether a delete-backward keystroke should pop the rename input back to the
/// command list, and whether dismissing the palette should restore a browser
/// address-bar's focus.
public struct CommandPaletteCommandRunPolicy {
    /// Creates the policy. The type holds no state; its predicates are derived
    /// entirely from their arguments.
    public init() {}

    /// Whether the palette overlay must be dismissed before the command runs.
    ///
    /// Fork-conversation commands and browser focus mode focus a target view
    /// synchronously, so the palette's `makeFirstResponder(nil)` on dismissal
    /// would otherwise clear that freshly-set focus. Dismissing first avoids it.
    public func shouldDismissBeforeRun(forCommandId commandId: String) -> Bool {
        switch commandId {
        case "palette.forkAgentConversationRight",
             "palette.forkAgentConversationLeft",
             "palette.forkAgentConversationTop",
             "palette.forkAgentConversationBottom",
             "palette.forkAgentConversationNewTab",
             "palette.forkAgentConversationNewWorkspace",
             // Entering browser focus mode focuses the web view synchronously;
             // dismiss the palette first so its makeFirstResponder(nil) doesn't
             // clear that focus and leave focus mode active without key routing.
             "palette.browserFocusMode":
            return true
        default:
            return false
        }
    }

    /// Whether a delete-backward keystroke on an empty rename input (with no
    /// command/control/option/shift held) should pop the palette back to the
    /// command list instead of editing text.
    public func shouldPopRenameInputOnDelete(
        renameDraft: String,
        modifiers: EventModifiers
    ) -> Bool {
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return renameDraft.isEmpty
    }

    /// Whether dismissing the palette should restore the browser address bar's
    /// focus, i.e. the focused panel is a browser whose address bar previously
    /// held focus.
    public func shouldRestoreBrowserAddressBarAfterDismiss(
        focusedPanelIsBrowser: Bool,
        focusedBrowserAddressBarPanelId: UUID?,
        focusedPanelId: UUID?
    ) -> Bool {
        focusedPanelIsBrowser && focusedBrowserAddressBarPanelId == focusedPanelId
    }
}
