public import CmuxNextDesign
import Foundation

nonisolated extension SidebarWorkspaceStatus.Entry {
    /// The key of ``bypass``: no reporter's entry (a reported one under this key is replaced).
    public static let bypassKey = "cmux.agent.bypass"

    /// The row's warning that a chat in the workspace runs in a mode that does not ask before it
    /// acts (another machine's chat opened here in bypass mode), first in the status block.
    public static var bypass: Self {
        Self(key: bypassKey, text: Strings.agentBypass, icon: "exclamationmark.shield.fill", tint: .palette(.red), state: "error")
    }
}

nonisolated extension Strings {
    static var agentBypass: String {
        String(localized: "sidebar.workspace.agentBypass", defaultValue: "Bypass: acts without asking", bundle: .module)
    }
}
