import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages

/// The user-only confirmation every person-only action (`ActionCatalog.personOnlyEffectIDs`)
/// shows when it runs in the app without its own prompt (cx-zk9t). The registry's gate asks
/// for it on every in-app surface (menu, palette, shortcut, context menu, page), so a run an
/// agent starts there (an AX press of the menu item, posted palette keys) still stops at a
/// dialog whose confirm automation can never press.
enum PersonOnlyConfirmation {
    /// What each person-only action grants: the kind of its confirm button.
    static func kind(of id: ActionID) -> CmuxDialogConfirmKind {
        switch id.rawValue {
        case "cloudResizeMachine", "palette.cloud.fork": .money
        case "browser.prompt.allow", "browser.pageInfo.setPermission", "cloudFirewallCreate", "cloudTunnelRotateKey",
             "palette.cloud.handoff", "remote.install", "cloudCopyLink":
            .trust
        default: .destructive
        }
    }

    /// The generic question for a person-only action: its own title, and Continue.
    static func prompt(for id: ActionID, _ registry: ActionRegistry) -> DestructiveConfirmation.Prompt? {
        guard let descriptor = registry.descriptor(for: id), descriptor.isPersonOnly else { return nil }
        let title = descriptor.title.hasSuffix("…") ? String(descriptor.title.dropLast()) : descriptor.title
        return DestructiveConfirmation.Prompt(title: title, body: "",
                                              button: PageConfirmation(kind: .custom, name: title).confirmTitle, kind: kind(of: id))
    }
}
