import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// Who turned Share This Mac on with no sheet, after the person's one yes
/// (`macScreen.shareWithoutAsking`). The person did not click anything, so the window
/// says who did, quietly: a toast on the window's overlay, never a sheet, never an
/// activation, never a key-window change. Leo, 2026-11-16: "just go figure out a less
/// obtrusive [way] to do that screen sharing shit".
enum CmuxRemoteShareCaller: Equatable {
    /// An agent: its chat's CLI or cmux MCP server, or a Chief turn.
    case agent
    /// A cmux CLI in a terminal no agent session names.
    case terminal
    /// The cmux CLI or a script with no caller of its own.
    case cli
    /// Another of the person's devices.
    case device

    /// The caller of a `remote.confirm` control request, from its `caller` object (`agent_session`,
    /// `terminal_id`, `home_chat`); the cmux CLI when it names none.
    init(controlParams params: [String: JSONValue]) {
        guard case .object(let caller)? = params["caller"] else {
            self = .cli
            return
        }
        let named = { (key: String) in caller[key]?.stringValue.map { !$0.isEmpty } ?? false }
        if named("agent_session") || caller["home_chat"]?.boolValue == true {
            self = .agent
        } else if named("terminal_id") {
            self = .terminal
        } else {
            self = .cli
        }
    }

    /// The caller of an action run; nil for the person's own run in this app, which needs no notice.
    init?(invocation: ActionInvocation) {
        if invocation.callerAgentSession != nil || invocation.callerHomeChat {
            self = .agent
            return
        }
        switch invocation.origin {
        case .user where !invocation.viaControlSocket, .page: return nil
        case .mcp: self = .agent
        case .remote: self = .device
        case .user, .cli, .script: self = invocation.callerTerminal == nil ? .cli : .terminal
        }
    }

    var message: String {
        switch self {
        case .agent: L.t("macScreen.sharedBy.agent", "An agent turned on Share This Mac.")
        case .terminal: L.t("macScreen.sharedBy.terminal", "A command in a terminal turned on Share This Mac.")
        case .cli: L.t("macScreen.sharedBy.cli", "The cmux CLI turned on Share This Mac.")
        case .device: L.t("macScreen.sharedBy.device", "One of your devices turned on Share This Mac.")
        }
    }

    /// The toast, in `window` only. It never activates the app or changes the key window.
    func announce(in window: NSWindow?) {
        guard let window else { return }
        _ = CmuxToastCenter.shared.show(CmuxToast(id: "macScreen.sharedBy", message: message, duration: .seconds(8)), in: window)
    }
}
