import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextDevices
import Foundation

/// "My agents can turn screen sharing and control on my machines" in the app (docs/cmux-remote.md,
/// Agents). The daemon decides (cmux-tui-core `remote_host/agent_share.rs`); this only passes it
/// what the app alone knows (the hub's value of the permission, the account, this device) and
/// draws the result: the notice, the menu bar line, and the dialog where the daemon says to ask.
nonisolated struct CmuxRemoteAgentGrant: Sendable {
    /// The agent session, as the daemon saw it.
    var session: String
    /// How the notice names it (its name, else its session id).
    var label: String
    var notice: CmuxNextDaemon.JSONValue
    /// The change the ticket was minted for (`share` or `unshare`), as the daemon bound it.
    var action: String = ""
    /// The redeemed ticket: `agent.applied` names it once the hub write is done.
    var ticket: String = ""
}

@MainActor
enum CmuxRemoteAgentShare {
    /// Redeems an agent's ticket: the grant when the daemon says no dialog, nil when the person
    /// decides (the permission off, signed out, a forged or old ticket, a daemon without it).
    static func redeem(_ ticket: String, hub: DeviceHub, remote: CmuxRemoteService,
                       target: HubDevice? = nil) async throws -> CmuxRemoteAgentGrant? {
        guard remote.started else { return nil }
        // The hub's value now, not a cached one: the permission may have just gone off elsewhere.
        await hub.refreshSettings()
        if hub.me == nil { await hub.refreshMe() }
        var params: [String: CmuxNextDaemon.JSONValue] = [
            "ticket": .string(ticket),
            "allowed": .bool(hub.agentsMayShare),
            "account": .string(hub.me?.userId ?? ""),
            "this_device": .object(["id": .string(hub.identity.id), "name": .string(hub.thisDevice?.name ?? hub.deviceName)]),
        ]
        // A share the person already has on stays theirs: the daemon puts no agent countdown on it.
        if target == nil, hub.thisDevice?.macScreenShared == true { params["already_shared"] = .bool(true) }
        if let target {
            // Listed among this account's devices: the same account (the hub lists no other).
            params["target"] = .object(["id": .string(target.id), "name": .string(target.name), "account": .string(hub.me?.userId ?? "")])
        }
        let answer: CmuxNextDaemon.JSONValue
        do { answer = try await remote.call("agent.redeem", .object(params)) } catch {
            // Another account's device is refused outright; anything else (a daemon without agent
            // tickets, no daemon) leaves the decision to the person, as before.
            let text = String(describing: error)
            if text.contains("agents.other_account") || text.contains("is not a device of this account") { throw error }
            return nil
        }
        guard answer["dialog"]?.boolValue == false else { return nil }
        return CmuxRemoteAgentGrant(session: answer["agent"]?["session"]?.stringValue ?? "",
                                    label: answer["agent_label"]?.stringValue ?? "",
                                    notice: answer["notice"] ?? .null, action: answer["action"]?.stringValue ?? "", ticket: ticket)
    }

    /// Tells the daemon whether the granted change reached the hub: only a made change arms (or
    /// cancels) the agent's auto-off timer.
    static func applied(_ grant: CmuxRemoteAgentGrant, ok: Bool, remote: CmuxRemoteService) async {
        guard remote.started, !grant.ticket.isEmpty else { return }
        _ = try? await remote.call("agent.applied", .object(["ticket": .string(grant.ticket), "ok": .bool(ok)]))
    }

    /// The person turned sharing on or off themselves: an agent's share stops counting down.
    static func personChanged(_ remote: CmuxRemoteService) async {
        guard remote.started else { return }
        _ = try? await remote.call("agent.person")
    }

    /// The quiet notice on this Mac for an agent's change, with Turn Off when it turned sharing
    /// on here; `turnOff` runs the same path as the palette's Stop Sharing This Mac.
    static func post(_ grant: CmuxRemoteAgentGrant, in window: NSWindow?, turnOff: @escaping @MainActor () -> Void) {
        let device = grant.notice["device_name"]?.stringValue ?? ""
        let on = grant.notice["kind"]?.stringValue == "shared"
        let offers = grant.notice["turn_off"]?.stringValue != nil
        post(message: on ? CmuxRemoteAgentStrings.shared(device) : CmuxRemoteAgentStrings.unshared(device), detail: CmuxRemoteAgentStrings.byAgent(grant.label),
             offersTurnOff: on && offers, in: window, turnOff: turnOff)
    }

    static func post(message: String, detail: String?, offersTurnOff: Bool, in window: NSWindow?,
                     turnOff: @escaping @MainActor () -> Void = {}) {
        guard let window = window ?? NSApp?.mainWindow ?? NSApp?.keyWindow else { return }
        let toast = CmuxToast(id: "remote.agents", kind: "remote.agents", message: message, detail: detail,
                              action: offersTurnOff ? CmuxToast.Action(title: CmuxRemoteAgentStrings.turnOff) : nil,
                              duration: .seconds(10))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        if offersTurnOff { handle.onAction = { turnOff() } }
    }
}

/// The strings of the agents' permission (`CmuxRemote` table).
nonisolated enum CmuxRemoteAgentStrings {
    static func shared(_ device: String) -> String {
        String(format: String(localized: "remote.agents.notice.shared", defaultValue: "%@ is now shared", table: "CmuxRemote", bundle: .module), device)
    }
    static func unshared(_ device: String) -> String {
        String(format: String(localized: "remote.agents.notice.unshared", defaultValue: "%@ is no longer shared", table: "CmuxRemote", bundle: .module), device)
    }
    static func byAgent(_ agent: String) -> String {
        String(format: String(localized: "remote.agents.notice.byAgent", defaultValue: "Your agent %@ did this.", table: "CmuxRemote", bundle: .module), agent)
    }
    static var turnOff: String {
        String(localized: "remote.agents.notice.turnOff", defaultValue: "Turn Off", table: "CmuxRemote", bundle: .module)
    }
    /// The menu bar item's line while an agent's share is on with no viewer.
    static func indicator(_ agent: String) -> String {
        String(format: String(localized: "remote.agents.indicator", defaultValue: "Shared by your agent %@; turns off with no viewer", table: "CmuxRemote", bundle: .module), agent)
    }
    static var allowTitle: String {
        String(localized: "remote.agents.allow.title", defaultValue: "Let your agents share your machines?", table: "CmuxRemote", bundle: .module)
    }
    static var allowBody: String {
        String(localized: "remote.agents.allow.body",
               defaultValue: "Your agents on your own devices can then turn screen sharing and control on or off for your Macs without asking. Each change shows a notice with Turn Off, and sharing an agent turned on turns off after a few minutes with no viewer. Other people and their agents still ask.",
               table: "CmuxRemote", bundle: .module)
    }
    static var allowed: String {
        String(localized: "remote.agents.allowed", defaultValue: "Your agents can now share your machines", table: "CmuxRemote", bundle: .module)
    }
    static var disallowed: String {
        String(localized: "remote.agents.disallowed", defaultValue: "Your agents now ask before sharing your machines", table: "CmuxRemote", bundle: .module)
    }
    /// Settings > Devices: the account's permission.
    static var settingsToggle: String {
        String(localized: "remote.agents.settings.toggle", defaultValue: "My agents can turn screen sharing and control on my machines", table: "CmuxRemote", bundle: .module)
    }
    static var settingsDetail: String {
        String(localized: "remote.agents.settings.detail",
               defaultValue: "Your agents share without asking, with a notice each time.",
               table: "CmuxRemote", bundle: .module)
    }
    static var historyAllowed: String {
        String(localized: "remote.agents.history.allowed", defaultValue: "Agents allowed to share", table: "CmuxRemote", bundle: .module)
    }
    static var historyDisallowed: String {
        String(localized: "remote.agents.history.disallowed", defaultValue: "Agents ask before sharing", table: "CmuxRemote", bundle: .module)
    }
}
