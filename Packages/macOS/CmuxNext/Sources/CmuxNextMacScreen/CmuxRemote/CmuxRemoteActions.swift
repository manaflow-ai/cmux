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
    /// SECURITY: whether the press answering the "Share This Mac" sheet shown in the given window, read
    /// as it answers, is the person's own (``pressedByPerson(_:in:now:isPerson:)`` on the input event the
    /// app is dispatching then). Only then is Always Allow kept; any other press allows this request once.
    /// None set: never kept.
    public var personPressed: @MainActor (NSWindow) -> Bool
    /// Which account's Always Allow counts (``RemoteShareGrant``); none: the setting alone never skips.
    public var shareGrant: @MainActor () -> RemoteShareGrant?

    public init(remote: CmuxRemoteService, screenHost: MacScreenHubHost, hub: @escaping @MainActor () -> DeviceHub?,
                settings: @escaping @MainActor () -> SettingsController? = { nil }, window: @escaping @MainActor () -> NSWindow?,
                shareGrant: @escaping @MainActor () -> RemoteShareGrant? = { nil },
                openDevices: @escaping @MainActor () -> Void, personPressed: @escaping @MainActor (NSWindow) -> Bool = { _ in false }) {
        self.remote = remote
        self.screenHost = screenHost
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
                let grant = environment.shareGrant(), personPressed = environment.personPressed
                let step = Self.shareStep(alreadyShared: hub.thisDevice?.macScreenShared == true,
                                          withoutAsking: Self.withoutAsking(settings: settings, grant: grant))
                // The setup sheet asks and turns sharing on itself, so its answer is the change.
                return .followUp(Self.confirmedChange(
                    confirm: {
                        let setup = CmuxRemoteSharingSetup(host: screenHost)
                        let present = { (spec: CmuxDialogSpec) async -> String in
                            guard let window else { return "cancel" }
                            return await CmuxDialogCenter.shared.present(spec, in: .window(window)).button
                        }
                        switch step {
                        case .nothing, .apply:
                            return try await Self.shareWithoutOverview(step, setup: setup, present: present)
                        case .ask:
                            guard let window else { return false }
                            let answer = try await setup.confirmRequest(in: window, personPressed: personPressed)
                            // Written first, then recorded: a record never sits beside the setting off. No account, nothing.
                            if answer.always, let settings, let grant, grant.account != nil, await Self.shareWithoutAsking(settings) {
                                grant.record()
                            }
                            return answer.shared
                        }
                    },
                    apply: {}))
            }.withDeadline(.fixed(.seconds(130))),
        ]
    }

    /// The `remote.confirm` access dialog's id. `DebugDialog.userOnly` lists it and the share
    /// request's overview (`cmux.dialog.screenSharing.setup.overview`, whose Always Allow turns on
    /// the user-only `remote.shareWithoutAsking`): no debug press answers either.
    public static let confirmIdentifier = "cmux.dialog.remote.confirm"

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

    /// A share request with no overview: `.apply` (Always Allow) turns sharing on, and a missing
    /// macOS grant still gets its own step. `.nothing` (this Mac already shares) writes nothing to the
    /// hub, but a missing grant still gets its steps: a share that cannot capture is not done.
    static func shareWithoutOverview(_ step: ShareStep, setup: CmuxRemoteSharingSetup,
                                     present: (CmuxDialogSpec) async -> String) async throws -> Bool {
        guard step == .apply else { return true }
        return try await setup.proceed(after: "continue", present: present)
    }

    /// Whether a share request may skip the overview: `remote.shareWithoutAsking` is on and the
    /// signed-in account's person chose Always Allow, or a managing team pinned it (``RemoteShareGrant``).
    /// No grant: the setting alone never skips.
    static func withoutAsking(settings: SettingsController?, grant: RemoteShareGrant?) -> Bool {
        guard let settings, let grant else { return false }
        return grant.covers(settingOn: settings.snapshot.remote.shareWithoutAsking,
                            managed: settings.managedKeys[RemoteSettings.shareWithoutAskingPath.joined(separator: ".")] != nil)
    }

    /// SECURITY: whether `event`, the input event the app is dispatching as the sheet answers (nil
    /// outside a dispatch: an Accessibility press, a timer), is the person's own click or key on the
    /// sheet shown in `window`: a key or mouse-button event in `window` or one of its child windows (the
    /// overlay panel the sheet draws in) at most a second before `now` (system uptime) that `isPerson`
    /// (the strict HID-system check, `PersonInputCheck`) takes. A mouse move, an old event, an event in
    /// another window or none does not count.
    public static func pressedByPerson(_ event: NSEvent?, in window: NSWindow, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                       isPerson: (NSEvent) -> Bool) -> Bool {
        let windows = Set([window.windowNumber] + (window.childWindows ?? []).map(\.windowNumber))
        return pressedByPerson(event, inWindows: windows, now: now, isPerson: isPerson)
    }

    /// ``pressedByPerson(_:in:now:isPerson:)`` for the window numbers of the sheet's window and its
    /// overlay panel.
    static func pressedByPerson(_ event: NSEvent?, inWindows windows: Set<Int>, now: TimeInterval, isPerson: (NSEvent) -> Bool) -> Bool {
        guard let event, [.keyDown, .leftMouseDown, .leftMouseUp].contains(event.type), windows.contains(event.windowNumber) else { return false }
        return event.timestamp <= now && now - event.timestamp <= 1 && isPerson(event)
    }

    /// Always Allow: the person's click turns on `remote.shareWithoutAsking` (the user writer: the
    /// click is in this app's UI). False when refused or failed: the next request asks again.
    static func shareWithoutAsking(_ settings: SettingsController) async -> Bool {
        guard let descriptor = SettingsSchema.descriptor(for: RemoteSettings.shareWithoutAskingPath) else { return false }
        return (try? await settings.setSetting(descriptor, to: .bool(true), by: .user)) != nil
    }

    /// `remote.confirm`'s answer: the person's choice on the dialog, then the change it allows.
    ///
    /// The dialog outlives the request: the caller gives up after its deadline (the CLI waits
    /// 130 s), and the request's deadline cancels its follow-up. An Allow after that is still the
    /// person's answer, so the dialog and the change run in their own task, which the request's
    /// cancellation does not reach; the request only waits on it.
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
