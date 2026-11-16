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
    public var hub: @MainActor () -> DeviceHub?
    /// Settings: `remote.shareWithoutAsking`, which Always Allow on "Share This Mac?" turns on.
    public var settings: @MainActor () -> SettingsController?
    public var window: @MainActor () -> NSWindow?
    public var openDevices: @MainActor () -> Void
    /// SECURITY: whether the app's latest input, the press that answered the dialog, was the
    /// person's own (HID system, `PersonInputLedger.backs`, the check join consent takes). Only
    /// then is Always Allow kept; any other press allows this request once. None set: never kept.
    public var personPressed: @MainActor () -> Bool
    /// Which account's Always Allow counts (``RemoteShareGrant``); none: the setting alone never skips.
    public var shareGrant: @MainActor () -> RemoteShareGrant?

    public init(remote: CmuxRemoteService, hub: @escaping @MainActor () -> DeviceHub?,
                settings: @escaping @MainActor () -> SettingsController? = { nil }, window: @escaping @MainActor () -> NSWindow?,
                shareGrant: @escaping @MainActor () -> RemoteShareGrant? = { nil },
                openDevices: @escaping @MainActor () -> Void, personPressed: @escaping @MainActor () -> Bool = { false }) {
        self.remote = remote
        self.hub = hub
        self.settings = settings
        self.window = window
        self.openDevices = openDevices
        self.personPressed = personPressed
        self.shareGrant = shareGrant
    }
}

/// cmux Remote's palette actions (docs/cmux-remote.md, Settings and controls) and
/// `remote.confirm`, the app method `cmux remote-host` and the `remote_*` MCP tools use for a
/// change only the person may make (Share This Mac on, raising a device's access): the person
/// confirms it on a cmux dialog, then this app's hub session (the full one) makes it.
@MainActor
extension CmuxRemoteActionEnvironment {
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
        // The person runs these from the palette: no second question.
        for (id, on) in [("macScreen.shareThisMac", true), ("macScreen.stopSharingThisMac", false)] as [(ActionID, Bool)] {
            _ = registry.bindEffect(id, unavailable: { environment.hub() == nil ? CmuxRemoteStrings.signedOut : nil }, effect: { _ in
                guard let hub = environment.hub() else { return .refused(CmuxRemoteStrings.signedOut) }
                // action-wait-allow: the device hub owns the sharing switch; the Devices page follows its push.
                return .waiting(.network) {
                    do { try await Self.apply(on ? "share" : "unshare", device: "", scope: nil, hub: hub, remote: remote) } catch {
                        return ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error))
                    }
                    return nil
                }
            })
        }
        _ = registry.bindEffect("macScreen.deviceAccess", effect: { _ in
            environment.openDevices()
            return .done
        })
    }

    /// Makes a confirmed change with this app's full hub session.
    static func apply(_ action: String, device: String, scope: DeviceScope?, hub: DeviceHub, remote: CmuxRemoteService) async throws {
        switch action {
        case "grant":
            // Already shared (`ShareStep.nothing`): no hub write, but a missing Screen Recording grant still gets its ask.
            if remote.started { _ = try? await remote.call("request", .object(["permission": .string("screen-recording")])) }
        case "share":
            try await hub.setMacScreenShared(true)
            if remote.started { _ = try? await remote.call("request", .object(["permission": .string("screen-recording")])) }
        case "unshare":
            try await hub.setMacScreenShared(false)
        default:
            if let scope { try await hub.setPermission(host: hub.identity.id, viewer: device, scope: scope) }
        }
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
                let name = hub.devices.first { $0.id == device }?.name ?? device
                let share = action == "share"
                let (title, body) = share ? CmuxRemoteStrings.confirmShare()
                    : CmuxRemoteStrings.confirmAccess(device: name, scope: scope ?? .ask)
                let window = environment.window()
                let remote = environment.remote
                let settings = environment.settings()
                let personPressed = environment.personPressed
                let grant = environment.shareGrant()
                let withoutAsking = grant?.covers(settingOn: settings?.snapshot.remote.shareWithoutAsking == true,
                                                  managed: settings?.managedKeys[RemoteSettings.shareWithoutAskingPath.joined(separator: ".")] != nil) ?? false
                let step = !share ? ShareStep.ask : Self.shareStep(alreadyShared: hub.thisDevice?.macScreenShared == true,
                                                                     withoutAsking: withoutAsking)
                return .followUp(Self.confirmedChange(
                    confirm: {
                        guard step == .ask else { return true }
                        let answer = await Self.confirm(title: title, body: body, always: share, in: window)
                        if Self.keepsAlways(answer, personPressed: personPressed()), let settings, let grant {
                            grant.record()
                            await Self.shareWithoutAsking(settings)
                        }
                        return answer != .cancel
                    },
                    apply: {
                        try await Self.apply(step == .nothing ? "grant" : action, device: device, scope: scope, hub: hub, remote: remote)
                    }))
            }.withDeadline(.fixed(.seconds(130))),
        ]
    }

    /// The `remote.confirm` dialog's id (`DebugDialog.userOnly` lists it: no debug press answers it).
    public static let confirmIdentifier = "cmux.dialog.remote.confirm"

    /// What `remote.confirm {action: share}` does.
    nonisolated enum ShareStep: Equatable, Sendable {
        /// Show "Share This Mac?".
        case ask
        /// Turn sharing on with no dialog: the person chose Always Allow.
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

    /// Whether an answer turns on `remote.shareWithoutAsking`: Always Allow pressed by the person at
    /// this Mac. An Always Allow another process posted (computer use, a script) allows once.
    static func keepsAlways(_ answer: ConfirmAnswer, personPressed: Bool) -> Bool {
        answer == .always && personPressed
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
    /// 130 s), and the request's deadline cancels its follow-up. An Allow after that is still the
    /// person's answer, so the dialog and the change run in their own task, which the request's
    /// cancellation does not reach; the request only waits on it.
    nonisolated static func confirmedChange(confirm: @escaping @MainActor @Sendable () async -> Bool,
                                            apply: @escaping @Sendable () async throws -> Void) -> @Sendable () async throws -> CmuxNextSettings.JSONValue {
        {
            let answer = Task { () async throws -> CmuxNextSettings.JSONValue in
                guard await confirm() else { return ["ok": false, "declined": true] }
                try await apply()
                return ["ok": true]
            }
            return try await answer.value
        }
    }

    /// A confirm dialog's answer.
    enum ConfirmAnswer: Equatable {
        case cancel, allow, always
    }

    /// The person's answer to one dialog (cancel without a window). `always` adds Always Allow.
    static func confirm(title: String, body: String, always: Bool = false, in window: NSWindow?) async -> ConfirmAnswer {
        guard let window else { return .cancel }
        return await withCheckedContinuation { continuation in
            let spec = CmuxDialogSpec(title: title, lines: [body], buttons: Self.confirmButtons(always: always),
                                      identifier: Self.confirmIdentifier)
            CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
                continuation.resume(returning: answer.button == "confirm" ? .allow : answer.button == "always" ? .always : .cancel)
            }
        }
    }

    /// Cancel, then Always Allow when offered, then Allow (Return).
    static func confirmButtons(always: Bool) -> [CmuxDialogButton] {
        let allowAlways = always ? [CmuxDialogButton(id: "always", title: CmuxRemoteStrings.alwaysAllow)] : []
        return [CmuxDialogButton.cancel()] + allowAlways + [CmuxDialogButton(id: "confirm", title: CmuxRemoteStrings.allow, role: .default)]
    }
}
