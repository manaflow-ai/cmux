public import AppKit
public import CmuxNextActions
public import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextDevices
import Foundation

/// What cmux Remote's actions need from the app: the hub, a window to ask in, and Settings.
public struct CmuxRemoteActionEnvironment {
    public var remote: CmuxRemoteService
    public var hub: @MainActor () -> DeviceHub?
    public var window: @MainActor () -> NSWindow?
    public var openDevices: @MainActor () -> Void

    public init(remote: CmuxRemoteService, hub: @escaping @MainActor () -> DeviceHub?, window: @escaping @MainActor () -> NSWindow?,
                openDevices: @escaping @MainActor () -> Void) {
        self.remote = remote
        self.hub = hub
        self.window = window
        self.openDevices = openDevices
    }
}

/// cmux Remote's palette actions (docs/cmux-remote.md, Settings and controls) and
/// `remote.confirm`, the app method `cmux remote-host` and the `remote_*` MCP tools use for a
/// change only the person may make (Share This Mac on, raising a device's access): the person
/// confirms it on a cmux dialog, then this app's hub session (the full one) makes it.
@MainActor
public enum CmuxRemoteActions {
    public static func bind(into registry: ActionRegistry, environment: CmuxRemoteActionEnvironment) {
        let remote = environment.remote
        let host: (ActionID, String, CmuxNextDaemon.JSONValue) -> Void = { id, method, params in
            _ = registry.bindEffect(id, unavailable: { remote.started ? nil : CmuxRemoteStrings.unavailable }, effect: { _ in
                // action-wait-allow: the request runs in cmux Remote, another process; it shows its own prompt or restarts a worker.
                .waiting(.externalProcess) {
                    do { _ = try await remote.call(method, params) } catch { return ActionWorkFailure(String(describing: error)) }
                    return nil
                }
            })
        }
        host("remote.refreshPermissions", "refresh", .object([:]))
        host("remote.allowAccessibility", "request", .object(["permission": .string("accessibility")]))
        host("remote.allowScreenRecording", "request", .object(["permission": .string("screen-recording")]))
        host("remote.restartComputerUse", "restart", .object(["worker": .string("computer-use")]))
        host("remote.restartScreenSharing", "restart", .object(["worker": .string("screen-sharing")]))
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
                    do { try await apply(on ? "share" : "unshare", device: "", scope: nil, hub: hub, remote: remote) } catch {
                        return ActionWorkFailure(String(describing: error))
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
    public static func methods(environment: CmuxRemoteActionEnvironment) -> [ControlMethod] {
        [
            .mainActor("remote.confirm") { call in
                let action = call.params["action"]?.stringValue ?? ""
                let device = call.params["device"]?.stringValue ?? ""
                let scope = call.params["scope"]?.stringValue.flatMap(DeviceScope.init(rawValue:))
                guard action == "share" || (action == "access" && !device.isEmpty && scope != nil) else {
                    throw ControlError.invalidParams("action must be share, or access with device and scope (none, ask, view, full)")
                }
                guard let hub = environment.hub() else { throw ControlError.invalidParams(CmuxRemoteStrings.signedOut) }
                let name = hub.devices.first { $0.id == device }?.name ?? device
                let (title, body) = action == "share" ? CmuxRemoteStrings.confirmShare()
                    : CmuxRemoteStrings.confirmAccess(device: name, scope: scope ?? .ask)
                let window = environment.window()
                let remote = environment.remote
                return .followUp {
                    guard await confirm(title: title, body: body, in: window) else { return ["ok": false, "declined": true] }
                    try await apply(action, device: device, scope: scope, hub: hub, remote: remote)
                    return ["ok": true]
                }
            }.withDeadline(.fixed(.seconds(130))),
        ]
    }

    /// The person's answer to one dialog (false without a window).
    static func confirm(title: String, body: String, in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let spec = CmuxDialogSpec(title: title, lines: [body],
                                      buttons: [.cancel(), CmuxDialogButton(id: "confirm", title: CmuxRemoteStrings.allow, role: .default)],
                                      identifier: "cmux.dialog.remote.confirm")
            CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
                continuation.resume(returning: answer.button == "confirm")
            }
        }
    }
}
