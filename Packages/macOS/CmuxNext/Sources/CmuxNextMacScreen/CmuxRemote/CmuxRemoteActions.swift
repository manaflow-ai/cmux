public import AppKit
public import CmuxNextActions
public import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextDevices
public import CmuxNextSettings
import Foundation

/// What cmux Remote's actions need from the app: the hub, a window to ask in, and Settings.
public struct CmuxRemoteActionEnvironment {
    public var remote: CmuxRemoteService
    public var screenHost: MacScreenHubHost
    public var hub: @MainActor () -> DeviceHub?
    /// Settings: `remote.shareWithoutAsking`, which Always Allow on "Share This Mac" turns on.
    public var settings: @MainActor () -> SettingsController?
    public var window: @MainActor () -> NSWindow?
    public var openDevices: @MainActor () -> Void

    public init(remote: CmuxRemoteService, screenHost: MacScreenHubHost, hub: @escaping @MainActor () -> DeviceHub?,
                settings: @escaping @MainActor () -> SettingsController? = { nil }, window: @escaping @MainActor () -> NSWindow?,
                openDevices: @escaping @MainActor () -> Void) {
        self.remote = remote
        self.screenHost = screenHost
        self.hub = hub
        self.settings = settings
        self.window = window
        self.openDevices = openDevices
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
        let host: (ActionID, String, CmuxNextDaemon.JSONValue) -> Void = { id, method, params in
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
                let spec = CmuxDialogSpec(title: CmuxRemoteStrings.statusTitle, lines: CmuxRemoteStrings.statusLines(status),
                                          buttons: [CmuxDialogButton(id: "ok", title: CmuxRemoteStrings.done, role: .default)],
                                          identifier: "cmux.dialog.remote.status")
                CmuxDialogCenter.shared.present(spec, in: .window(window)) { _ in }
                return nil
            }
        })
        _ = registry.bindEffect("macScreen.shareThisMac", unavailable: { environment.hub() == nil ? CmuxRemoteStrings.signedOut : nil }, effect: { invocation in
            guard environment.hub() != nil else { return .refused(CmuxRemoteStrings.signedOut) }
            guard let window = environment.window() else { return .refused(L.t("macScreen.setup.noWindow", "Open a cmux window to share this Mac.")) }
            return CmuxRemoteSharingSetup(host: environment.screenHost).begin(in: window, invocation: invocation)
        })
        _ = registry.bindEffect("macScreen.stopSharingThisMac", effect: { _ in
            // Stop locally on this turn, even when the hub cannot be reached.
            environment.screenHost.stopSession(reason: .hostStopped, immediately: true)
            return .applied(result: {
                do { try await environment.screenHost.setSharing(false) }
                catch { return .failure(ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error))) }
                return .success([:])
            })
        })
        _ = registry.bindEffect("macScreen.revokeViewer", unavailable: { environment.screenHost.noSessionReason }, effect: { _ in
            _ = environment.screenHost.revokeViewer()
            return .done
        })
        _ = registry.bindEffect("macScreen.deviceAccess", effect: { _ in
            environment.openDevices()
            return .done
        })
    }

    /// Makes a confirmed change with this app's full hub session.
    static func applyAccess(device: String, scope: DeviceScope?, hub: DeviceHub) async throws {
        if let scope { try await hub.setPermission(host: hub.identity.id, viewer: device, scope: scope) }
    }

    /// `remote.confirm {action: share|access, device?, scope?}`.
    public func controlMethods() -> [ControlMethod] {
        let environment = self
        return [
            .mainActor("remote.confirm") { call in
                let action = call.params["action"]?.stringValue ?? ""
                let device = call.params["device"]?.stringValue ?? ""
                let scope = call.params["scope"]?.stringValue.flatMap(DeviceScope.init(rawValue:))
                guard action == "share" || (action == "access" && !device.isEmpty && scope != nil) else {
                    throw ControlError.invalidParams("action must be share, or access with device and scope (none, ask, view, full)")
                }
                guard let hub = environment.hub() else { throw ControlError.invalidParams(CmuxRemoteStrings.signedOut) }
                if action == "share", !device.isEmpty {
                    return try Self.confirmShareOther(device, hub: hub, window: environment.window())
                }
                let name = hub.devices.first { $0.id == device }?.name ?? device
                let window = environment.window()
                guard action == "share" else {
                    let (title, body) = CmuxRemoteStrings.confirmAccess(device: name, scope: scope ?? .ask)
                    return .followUp(Self.confirmedChange(
                        confirm: { await Self.confirm(title: title, body: body, in: window) },
                        apply: { try await Self.applyAccess(device: device, scope: scope, hub: hub) }))
                }
                let screenHost = environment.screenHost
                let settings = environment.settings()
                let step = Self.shareStep(alreadyShared: hub.thisDevice?.macScreenShared == true,
                                          withoutAsking: settings?.snapshot.remote.shareWithoutAsking == true)
                // The setup sheet asks and turns sharing on itself, so its answer is the change.
                return .followUp(Self.confirmedChange(
                    confirm: {
                        let setup = CmuxRemoteSharingSetup(host: screenHost)
                        switch step {
                        case .nothing:
                            return true
                        case .apply:
                            // Always Allow skips the overview; a missing macOS grant still gets its own step.
                            return try await setup.proceed(after: "continue") { spec in
                                guard let window else { return "cancel" }
                                return await CmuxDialogCenter.shared.present(spec, in: .window(window)).button
                            }
                        case .ask:
                            guard let window else { return false }
                            let answer = try await setup.confirmRequest(in: window)
                            if answer.always, let settings { await Self.shareWithoutAsking(settings) }
                            return answer.shared
                        }
                    },
                    apply: {}))
            }.withDeadline(.fixed(Self.confirmationTimeout)),
        ]
    }

    /// What `remote.confirm {action: share}` does.
    nonisolated enum ShareStep: Equatable, Sendable {
        /// Show the "Share This Mac" overview.
        case ask
        /// Turn sharing on with no overview: the person chose Always Allow.
        case apply
        /// Nothing: this Mac already shares. No write either, so a hub list that is behind (the
        /// person just stopped sharing on another device) never turns sharing back on.
        case nothing
    }

    /// The share request's step. Leo, 2026-11-16: "i dont want to have to click share this mac
    /// allow every single time when screen sharing". `remote.shareWithoutAsking` is user-only:
    /// settings.set from an agent, the CLI or MCP is refused.
    nonisolated static func shareStep(alreadyShared: Bool, withoutAsking: Bool) -> ShareStep {
        alreadyShared ? .nothing : withoutAsking ? .apply : .ask
    }

    /// Always Allow: the person's click turns on `remote.shareWithoutAsking` (the user writer: the
    /// click is in this app's UI). A refused or failed write only means the next request asks again.
    static func shareWithoutAsking(_ settings: SettingsController) async {
        guard let descriptor = SettingsSchema.descriptor(for: RemoteSettings.shareWithoutAskingPath) else { return }
        try? await settings.setSetting(descriptor, to: .bool(true), by: .user)
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
    static func confirmShareOther(_ device: String, hub: DeviceHub, window: NSWindow?) throws -> ControlReply {
        guard let target = hub.otherDevices.first(where: { $0.id == device || $0.name.caseInsensitiveCompare(device) == .orderedSame }) else {
            throw ControlError.invalidParams(CmuxRemoteStrings.notYourDevice(device))
        }
        let (title, body) = CmuxRemoteStrings.confirmShareOther(device: target.name)
        let unsigned = CmuxRemoteShareApproval(target: target.id, targetName: target.name, asker: hub.identity.id,
                                               askerName: hub.thisDevice?.name ?? hub.deviceName, confirmedBy: hub.me?.userId ?? "",
                                               confirmedAt: 0, nonce: UUID().uuidString.lowercased())
        let identity = hub.identity
        return .followUp {
            guard await Self.confirm(title: title, body: body, in: window) else { return ["ok": false, "declined": true] }
            var approval = unsigned
            approval.confirmedAt = Int(Date().timeIntervalSince1970)
            let signed = try approval.signed(by: identity)
            return .object(["ok": true, "approval": signed.json])
        }
    }

    /// The person's answer to one dialog (false without a window).
    static func confirm(title: String, body: String, in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let spec = CmuxDialogSpec(title: title, lines: [body],
                                      buttons: [.cancel(), CmuxDialogButton(id: "confirm", title: CmuxRemoteStrings.allow, role: .default)],
                                      identifier: Self.confirmIdentifier)
            CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
                continuation.resume(returning: answer.button == "confirm")
            }
        }
    }
}
