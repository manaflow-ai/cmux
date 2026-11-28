import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

/// Who turned Share This Mac on with no sheet, after the person's one yes
/// (`macScreen.shareWithoutAsking`). The person did not click anything, so the window
/// says who did, quietly: a toast on the window's overlay, never a sheet, never an
/// activation, never a key-window change. Leo, 2026-11-16: "just go figure out a less
/// obtrusive [way] to do that screen sharing shit".
enum CmuxRemoteShareCaller: String, Equatable {
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
        let answer = RdUI.call("remote.callerFromParams", encoding: params) as? [String: Any]
        self = (answer?["caller"] as? String).flatMap(Self.init(rawValue:)) ?? .cli
    }

    /// The caller of an action run; nil for the person's own run in this app, which needs no notice.
    init?(invocation: ActionInvocation) {
        let answer = RdUI.call("remote.callerFromInvocation", [
            "agentSession": invocation.callerAgentSession != nil, "homeChat": invocation.callerHomeChat,
            "origin": invocation.origin.rawValue, "viaControlSocket": invocation.viaControlSocket, "terminal": invocation.callerTerminal != nil,
        ]) as? [String: Any]
        guard let caller = (answer?["caller"] as? String).flatMap(Self.init(rawValue:)) else { return nil }
        self = caller
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
