public import AppKit
public import CmuxNextActions
public import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextDevices
import CmuxNextSettings
import Foundation

/// What cmux Remote's actions need from the app: the hub, a window to ask in, and Settings.
public struct CmuxRemoteActionEnvironment {
    public var remote: CmuxRemoteService
    public var screenHost: MacScreenHubHost
    public var hub: @MainActor () -> DeviceHub?
    public var window: @MainActor () -> NSWindow?
    public var openDevices: @MainActor () -> Void
    /// This Mac as a hub host: its menu bar item shows an owner's agent's share.
    public var hubHost: @MainActor () -> MacScreenHubHost?
    /// `macScreen.shareWithoutAsking`: the person's one yes to Share This Mac.
    public var shareConsent: CmuxRemoteShareConsent

    public init(remote: CmuxRemoteService, screenHost: MacScreenHubHost, hub: @escaping @MainActor () -> DeviceHub?, window: @escaping @MainActor () -> NSWindow?,
                openDevices: @escaping @MainActor () -> Void,
                shareConsent: CmuxRemoteShareConsent = CmuxRemoteShareConsent(given: { false }, remember: {})) {
        self.remote = remote
        self.screenHost = screenHost
        self.hub = hub
        self.window = window
        self.openDevices = openDevices
        self.hubHost = { [screenHost] in screenHost }
        self.shareConsent = shareConsent
    }
}

/// cmux Remote's palette actions (docs/cmux-remote.md, Settings and controls) and
/// `remote.confirm`, the app method `cmux remote-host` and the `remote_*` MCP tools use for a
/// change only the person may make (Share This Mac on, raising a device's access): the person
/// confirms it on a cmux dialog, then this app's hub session (the full one) makes it.
@MainActor
extension CmuxRemoteActionEnvironment {
    /// How long `remote.confirm` keeps its dialog open for the person. It is the same budget
    /// as `cmux remote-host`'s `CONFIRM_TIMEOUT`, so a late Allow still reaches the waiting
    /// CLI or MCP call and is not cancelled at the old 130 s.
    nonisolated static let confirmationTimeout: Duration = .seconds(600)

    /// The dialog for every `remote.confirm` change (Share This Mac, a device's access, sharing
    /// another Mac, whose Allow signs an approval with this device's key). Only the person answers
    /// it: the app's debug socket (`debug.dialog` press, key or dismiss) refuses it, or an agent
    /// could ask and then approve its own request (`DebugDialog.userOnly`).
    public nonisolated static let confirmIdentifier = "cmux.dialog.remote.confirm"

    /// Share This Mac's setup sheet, whose last step turns sharing on: user-only for the same reason.
    public nonisolated static let setupIdentifiers = Set(CmuxRemoteSharingSetup.Step.allCases.map(CmuxRemoteSharingSetup.identifier))

    public func bind(into registry: ActionRegistry) {
        let environment = self
        let remote = environment.remote
        // Every person's switch of sharing (Devices, Home, the palette, the setup sheet, a notice's
        // Turn Off) goes through `setSharing`: an agent's share stops counting down then.
        screenHost.personChangedSharing = { await CmuxRemoteAgentShare.personChanged(remote) }
        let host:(ActionID, String, CmuxNextDaemon.JSONValue) -> Void = { id, method, params in
            _ = registry.bindEffect(id, unavailable: { remote.started ? nil : CmuxRemoteStrings.unavailable }, effect: { _ in
                // action-wait-allow: the request runs in cmux Remote, another process; it shows its own prompt or restarts a worker.
                .waiting(.externalProcess) {
                    do { _ = try await remote.call(method, params) } catch { return ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error)) }
                    return nil
                }
            })
        }
        host("remote.refreshPermissions", "refresh", .object([:]))
        host("remote.allowAccessibility", "request", .object(["permission": .string("accessibility")]))
        host("remote.allowScreenRecording", "request", .object(["permission": .string("screen-recording")]))
        host("remote.restartComputerUse", "restart", .object(["worker": .string("computer-use")]))
        host("remote.restartScreenSharing", "restart", .object(["worker": .string("screen-sharing")]))
        // Stop Sharing This Mac (MacScreenActions) ends this session now; this row leaves the catalog with the
        // next re-pin, and then this bind finds no descriptor and does nothing.
        host("remote.stopScreenSession", "screen.stop_session", .object([:]))
        _ = registry.bindEffect("remote.showStatus", unavailable: { remote.started ? nil : CmuxRemoteStrings.unavailable }, effect: { _ in
            // action-wait-allow: the status comes from the daemon and cmux Remote, other processes; the dialog shows it.
            .waiting(.externalProcess) {
                let status = (try? await remote.status()) ?? .null
                guard let window = environment.window() else { return nil }
                let spec = CmuxDialogSpec(usesTransientMaterial: true, title: CmuxRemoteStrings.statusTitle, lines: CmuxRemoteStrings.statusLines(status),
                                          buttons: [CmuxDialogButton(id: "ok", title: CmuxRemoteStrings.done, role: .default)],
                                          identifier: "cmux.dialog.remote.status")
                CmuxDialogCenter.shared.present(spec, in: .window(window)) { _ in }
                return nil
            }
        })
        _ = registry.bindEffect("macScreen.shareThisMac", unavailable: { environment.hub() == nil ? CmuxRemoteStrings.signedOut : nil }, effect: { invocation in
            guard environment.hub() != nil else { return .refused(CmuxRemoteStrings.signedOut) }
            guard let window = environment.window() else { return .refused(L.t("macScreen.setup.noWindow", "Open a cmux window to share this Mac.")) }
            return CmuxRemoteSharingSetup(host: environment.screenHost, consent: environment.shareConsent).begin(in: window, invocation: invocation)
        })
        _ = registry.bindEffect("macScreen.stopSharingThisMac", effect: { invocation in
            // The person's own Stop is their off: the join default no longer turns sharing back on here.
            // The CLI's and agents' stops are not (`cmux remote-host share off` then `on` needs no sheet).
            if invocation.isPersonsOwnRun && ActionRunScope.isPersonsAction() { CmuxRemoteShareConsent.recordDecline() }
            // Stop locally on this turn, even when the hub cannot be reached.
            environment.screenHost.stopSession(reason: .hostStopped, immediately: true)
            return .applied(result: {
                do { try await environment.screenHost.setSharing(false) }
                catch { return .failure(ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error))) }
                return .success([:])
            })
        })
        // `macScreen.revokeViewer` is MacScreenActions' (the same host, `macScreenPages.hubHost`): binding it here too
        // was a second owner (CatalogRequestHandlersTests.everyRequestRowIsBound, `duplicateBindings`).
        _ = registry.bindEffect("macScreen.deviceAccess", effect: { _ in
            environment.openDevices()
            return .done
        })
    }

    /// Makes a confirmed change with this app's full hub session; `agent` names the owner's agent
    /// when the account's standing permission made it with no dialog (the hub's audit row).
    static func apply(_ action: String, device: String, scope: DeviceScope?, hub: DeviceHub, remote: CmuxRemoteService,
                      agent: HubAgentActor? = nil) async throws {
        switch action {
        case "share":
            if let agent { try await hub.setMacScreenShared(true, agent: agent) } else { try await hub.setMacScreenShared(true) }
            if remote.started { _ = try? await remote.call("request", .object(["permission": .string("screen-recording")])) }
        case "unshare":
            if let agent { try await hub.setMacScreenShared(false, agent: agent) } else { try await hub.setMacScreenShared(false) }
        default:
            try await applyAccess(device: device, scope: scope, hub: hub)
        }
    }

    /// Makes a confirmed change with this app's full hub session.
    static func applyAccess(device: String, scope: DeviceScope?, hub: DeviceHub) async throws {
        if let scope { try await hub.setPermission(host: hub.identity.id, viewer: device, scope: scope) }
    }

    /// `remote.confirm {action: share|unshare|access|allow_agents, device?, scope?, on?, agent_ticket?}`.
    ///
    /// - `share` (and `unshare`, which needs `agent_ticket`): with an agent's ticket and the
    ///   account's "My agents can turn screen sharing and control on my machines" on, the change
    ///   runs with no dialog, with a notice and the menu bar line (the daemon decides,
    ///   ``CmuxRemoteAgentShare/redeem(_:hub:remote:target:)``); otherwise the dialog, as before
    ///   (`unshare` then answers `{ok: false, asks_person: true}` and the caller turns it off
    ///   through the daemon).
    /// - `allow_agents {on}`: the permission itself. On always asks the person here, whatever the
    ///   caller (`cmux device setup --allow-agents` included); a ticket never skips it. Off needs
    ///   no dialog (it only takes a power away). Both write the hub's audit row and post a notice.
    public func controlMethods() -> [ControlMethod] {
        let environment = self
        return [
            .mainActor("remote.confirm") { call in
                // Rust checks the request (remote.confirmRequest) and names its refusal.
                let checked = RdUI.answer("remote.confirmRequest", encoding: call.params)
                guard let request = checked.ok as? [String: Any], let action = request["action"] as? String,
                      let kind = request["kind"] as? String else {
                    throw ControlError.invalidParams(checked.err ?? "remote.confirm: no answer")
                }
                let device = request["device"] as? String ?? ""
                let scope = (request["scope"] as? String).flatMap(DeviceScope.init(rawValue:))
                let ticket = request["ticket"] as? String
                guard let hub = environment.hub() else { throw ControlError.invalidParams(CmuxRemoteStrings.signedOut) }
                if kind == "allowAgents" {
                    return Self.allowAgents(request["on"] as? Bool ?? true, hub: hub, window: environment.window())
                }
                if kind == "shareOther" {
                    return try Self.confirmShareOther(device, hub: hub, window: environment.window(), ticket: ticket, remote: environment.remote)
                }
                let name = hub.devices.first { $0.id == device }?.name ?? device
                let window = environment.window()
                let remote = environment.remote
                let windowSource = environment.window, hubHost = environment.hubHost
                // The person's answer outlives the request (`confirmedChange`).
                let personConfirmed: @Sendable () async throws -> CmuxNextSettings.JSONValue
                if kind == "access" {
                    let (title, body) = CmuxRemoteStrings.confirmAccess(device: name, scope: scope ?? .ask)
                    personConfirmed = Self.confirmedChange(
                        confirm: { await Self.confirm(title: title, body: body, in: window) },
                        apply: { try await Self.applyAccess(device: device, scope: scope, hub: hub) })
                } else {
                    let screenHost = environment.screenHost, consent = environment.shareConsent
                    // The setup sheet asks and turns sharing on itself, so its answer is the change. After the
                    // person's one yes on this Mac, the owner's request turns sharing on with no sheet.
                    personConfirmed = Self.confirmedChange(
                        confirm: {
                            try await CmuxRemoteSharingSetup(host: screenHost, consent: consent)
                                .ownerRequest(in: window, by: CmuxRemoteShareCaller(controlParams: call.params))
                        },
                        apply: {})
                }
                return .followUp {
                    if let ticket, request["redeemsTicket"] as? Bool == true,
                       let grant = try await CmuxRemoteAgentShare.redeem(ticket, hub: hub, remote: remote) {
                        // The daemon decided for the ticket's own change: make that one (its timer waits for the write).
                        guard grant.action == action else {
                            throw ControlError.invalidParams("the agent ticket is for \(grant.action), not \(action)")
                        }
                        let device = try await Self.applyForAgent(grant, action: action, hub: hub, remote: remote,
                                                                  window: windowSource, hubHost: hubHost)
                        return ["ok": true, "agent": true, "device_name": .string(device)]
                    }
                    if kind == "unshare" { return ["ok": false, "asks_person": true] }
                    return try await personConfirmed()
                }
            }.withDeadline(.fixed(Self.confirmationTimeout)),
        ]
    }

    /// Makes an agent's change the daemon granted with no dialog, with this app's full hub session
    /// (the hub's audit row names the agent session and this device), then announces it: the
    /// notice, and the menu bar line while its share is on. Returns this device's name.
    static func applyForAgent(_ grant: CmuxRemoteAgentGrant, action: String, hub: DeviceHub, remote: CmuxRemoteService,
                              window: @escaping @MainActor () -> NSWindow?,
                              hubHost: @escaping @MainActor () -> MacScreenHubHost?) async throws -> String {
        let name = hub.thisDevice?.name ?? hub.deviceName
        do {
            try await apply(action, device: "", scope: nil, hub: hub, remote: remote, agent: HubAgentActor(session: grant.session, device: name))
        } catch {
            await CmuxRemoteAgentShare.applied(grant, ok: false, remote: remote)
            throw error
        }
        await CmuxRemoteAgentShare.applied(grant, ok: true, remote: remote)
        announce(grant, hub: hub, remote: remote, window: window, hubHost: hubHost)
        return name
    }

    /// The notice for an agent's change on this Mac, and the menu bar line while its share is on.
    static func announce(_ grant: CmuxRemoteAgentGrant, hub: DeviceHub, remote: CmuxRemoteService,
                         window: @escaping @MainActor () -> NSWindow?, hubHost: @escaping @MainActor () -> MacScreenHubHost?) {
        let turnOff: @MainActor () -> Void = {
            // task-owner: the notice's Turn Off, the palette's Stop Sharing This Mac path
            Task {
                if let host = hubHost() {
                    host.stopSession(reason: .hostStopped, immediately: true)
                    try? await host.setSharing(false)
                } else {
                    try? await Self.apply("unshare", device: "", scope: nil, hub: hub, remote: remote)
                    await CmuxRemoteAgentShare.personChanged(remote)
                }
            }
        }
        CmuxRemoteAgentShare.post(grant, in: window(), turnOff: turnOff)
        // Rust (agents.notice): the menu bar line shows while a share the agent turned on can be turned off.
        guard let notice = RdUI.call("agents.notice", encoding: ["notice": grant.notice]) as? [String: Any],
              notice["offersTurnOff"] as? Bool == true else { return }
        let device = notice["device"] as? String ?? ""
        hubHost()?.showAgentShare(CmuxRemoteAgentStrings.indicator(grant.label)) {
            CmuxRemoteAgentShare.post(message: CmuxRemoteAgentStrings.unshared(device), detail: nil, offersTurnOff: false, in: window())
        }
    }

    /// `remote.confirm {action: allow_agents, on}`: on asks the person on this Mac, always.
    static func allowAgents(_ on: Bool, hub: DeviceHub, window: NSWindow?) -> ControlReply {
        .followUp {
            if on {
                guard await Self.confirm(title: CmuxRemoteAgentStrings.allowTitle, body: CmuxRemoteAgentStrings.allowBody, in: window) else {
                    return ["ok": false, "declined": true]
                }
            }
            let now = try await setAgentsMayShare(on, hub: hub, window: window)
            return ["ok": true, "agents_may_share": .bool(now)]
        }
    }

    /// Writes the permission with this app's full hub session (the hub audits it) and posts the
    /// notice; the hub's value after the write.
    static func setAgentsMayShare(_ on: Bool, hub: DeviceHub, window: NSWindow?) async throws -> Bool {
        try await hub.setAgentsMayShare(on)
        CmuxRemoteAgentShare.post(message: on ? CmuxRemoteAgentStrings.allowed : CmuxRemoteAgentStrings.disallowed,
                                  detail: nil, offersTurnOff: false, in: window)
        return hub.agentsMayShare
    }

    /// `remote.confirm`'s answer: the person's choice on the dialog, then the change it allows.
    ///
    /// The dialog outlives the request: the caller gives up after its deadline (the CLI waits
    /// `confirmationTimeout`, 600 s), and the request's deadline cancels its follow-up. An Allow
    /// after that is still the person's answer, so the dialog and the change run in their own
    /// task, which the request's cancellation does not reach; the request only waits on it.
    nonisolated static func confirmedChange(confirm: @escaping @MainActor @Sendable () async throws -> Bool,
                                            apply: @escaping @Sendable () async throws -> Void) -> @Sendable () async throws -> CmuxNextSettings.JSONValue {
        {
            let answer = Task { () async throws -> CmuxNextSettings.JSONValue in
                guard try await confirm() else { return ["ok": false, "declined": true] }
                try await apply()
                return ["ok": true]
            }
            return try await answer.value
        }
    }

    /// `remote.confirm {action: share, device}`: share another Mac of this account. The person
    /// confirms here; only then does this device sign the approval the target Mac admits
    /// (`acpmux::share_approval`). Nothing turns on here: the target makes its own hub call.
    static func confirmShareOther(_ device: String, hub: DeviceHub, window: NSWindow?, ticket: String? = nil,
                                  remote: CmuxRemoteService? = nil) throws -> ControlReply {
        guard let target = hub.otherDevices.first(where: { $0.id == device || $0.name.caseInsensitiveCompare(device) == .orderedSame }) else {
            throw ControlError.invalidParams(CmuxRemoteStrings.notYourDevice(device))
        }
        let (title, body) = CmuxRemoteStrings.confirmShareOther(device: target.name)
        let unsigned = CmuxRemoteShareApproval(target: target.id, targetName: target.name, asker: hub.identity.id,
                                               askerName: hub.thisDevice?.name ?? hub.deviceName, confirmedBy: hub.me?.userId ?? "",
                                               confirmedAt: 0, nonce: UUID().uuidString.lowercased())
        let identity = hub.identity
        return .followUp {
            // The owner's agent under the account's standing permission: no dialog, a notice here.
            var grant: CmuxRemoteAgentGrant?
            if let ticket, let remote { grant = try await CmuxRemoteAgentShare.redeem(ticket, hub: hub, remote: remote, target: target) }
            if let grant {
                await CmuxRemoteAgentShare.post(grant, in: window) {}
            } else {
                guard await Self.confirm(title: title, body: body, in: window) else { return ["ok": false, "declined": true] }
            }
            var approval = unsigned
            approval.confirmedAt = Int(Date().timeIntervalSince1970)
            let signed = try approval.signed(by: identity)
            return .object(["ok": true, "approval": signed.json, "agent": .bool(grant != nil)])
        }
    }

    /// The person's answer to one dialog (false without a window).
    static func confirm(title: String, body: String, in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let spec = CmuxDialogSpec(usesTransientMaterial: true, title: title, lines: [body],
                                      buttons: [.cancel(), CmuxDialogButton(id: "confirm", title: CmuxRemoteStrings.allow, role: .default)],
                                      identifier: Self.confirmIdentifier)
            CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
                continuation.resume(returning: answer.button == "confirm")
            }
        }
    }
}
