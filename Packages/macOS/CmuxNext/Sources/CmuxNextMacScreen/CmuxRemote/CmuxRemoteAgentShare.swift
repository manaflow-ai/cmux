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
        // What to send and how to read the answer: Rust (cmux-rd-ffi `ui/agents.rs`).
        let args: [String: Any] = [
            "ticket": ticket, "allowed": hub.agentsMayShare, "account": hub.me?.userId ?? "",
            "thisDevice": ["id": hub.identity.id, "name": hub.thisDevice?.name ?? hub.deviceName],
            "alreadyShared": hub.thisDevice?.macScreenShared == true,
            "target": target.map { ["id": $0.id, "name": $0.name] as Any } ?? NSNull(),
        ]
        guard let params = RdUI.decode(RdUI.call("agents.redeemParams", args), as: CmuxNextDaemon.JSONValue.self) else { return nil }
        let answer: CmuxNextDaemon.JSONValue
        do { answer = try await remote.call("agent.redeem", params) } catch {
            // Another account's device is refused outright; anything else leaves the decision to the person.
            if RdUI.call("agents.redeemRefused", ["error": String(describing: error)]) as? Bool == true { throw error }
            return nil
        }
        guard let grant = RdUI.call("agents.redeemGrant", encoding: ["answer": answer]) as? [String: Any] else { return nil }
        return CmuxRemoteAgentGrant(session: grant["session"] as? String ?? "", label: grant["label"] as? String ?? "",
                                    notice: RdUI.decode(grant["notice"]) ?? .null, action: grant["action"] as? String ?? "",
                                    ticket: ticket)
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
        let notice = RdUI.call("agents.notice", encoding: ["notice": grant.notice]) as? [String: Any] ?? [:]
        let device = notice["device"] as? String ?? ""
        post(message: notice["kind"] as? String == "shared" ? CmuxRemoteAgentStrings.shared(device) : CmuxRemoteAgentStrings.unshared(device),
             detail: CmuxRemoteAgentStrings.byAgent(grant.label), offersTurnOff: notice["offersTurnOff"] as? Bool == true,
             in: window, turnOff: turnOff)
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
               defaultValue: "Agents on your own devices can turn screen sharing and control of your Macs on or off without asking. Each change shows a notice.",
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
}
