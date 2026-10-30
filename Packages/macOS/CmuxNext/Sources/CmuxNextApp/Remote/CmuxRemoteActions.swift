import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextDevices
import Foundation
import os

private let actionsLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cmux-remote")

/// cmux Remote's palette actions (docs/cmux-remote.md, Settings and controls) and
/// `remote.confirm`, the app method `cmux remote-host` and the `remote_*` MCP tools use for a
/// change only the person may make (Share This Mac on, raising a device's access): the person
/// confirms it on a cmux dialog, then this app's hub session (the full one) makes it.
enum CmuxRemoteActions {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let call: (String, CmuxNextDaemon.JSONValue) -> Void = { method, params in
            guard let remote = CmuxRemoteService.shared else { return context.refuse(CmuxRemoteStrings.unavailable) }
            // task-owner: one host request; a failure shows its reason.
            Task { @MainActor in
                do { _ = try await remote.call(method, params) } catch {
                    context.refuse(String(describing: error))
                }
            }
        }
        registry.bind("remote.showStatus", run: { _ in showStatus(context: context) })
        registry.bind("remote.refreshPermissions", run: { _ in call("refresh", .object([:])) })
        registry.bind("remote.allowAccessibility", run: { _ in call("request", .object(["permission": .string("accessibility")])) })
        registry.bind("remote.allowScreenRecording", run: { _ in call("request", .object(["permission": .string("screen-recording")])) })
        registry.bind("remote.restartComputerUse", run: { _ in call("restart", .object(["worker": .string("computer-use")])) })
        registry.bind("remote.restartScreenSharing", run: { _ in call("restart", .object(["worker": .string("screen-sharing")])) })
        // The person runs these from the palette: no second question.
        registry.bind("macScreen.shareThisMac", run: { _ in share(true, context: context) })
        registry.bind("macScreen.stopSharingThisMac", run: { _ in share(false, context: context) })
        registry.bind("macScreen.deviceAccess", run: { _ in
            try? context.services.settingsWindow.show(section: nil, route: "devices")
        })
    }

    /// Share This Mac on or off through this app's hub (a full session); on also asks macOS for
    /// cmux Remote's Screen Recording when it is missing.
    @MainActor static func share(_ on: Bool, context: AppActionContext) {
        guard let hub = context.services.macScreenPages.hub else { return context.refuse(CmuxRemoteStrings.signedOut) }
        // task-owner: one hub write the person asked for.
        Task { @MainActor in
            do {
                try await hub.setMacScreenShared(on)
                if on, let remote = CmuxRemoteService.shared {
                    _ = try? await remote.call("request", .object(["permission": .string("screen-recording")]))
                }
            } catch {
                context.refuse(String(describing: error))
            }
        }
    }

    /// The host, its workers and grants, on a dialog.
    @MainActor static func showStatus(context: AppActionContext) {
        guard let remote = CmuxRemoteService.shared else { return context.refuse(CmuxRemoteStrings.unavailable) }
        let window = context.services.windows.active?.window ?? NSApp.keyWindow
        // task-owner: one status read, then the dialog.
        Task { @MainActor in
            let status = (try? await remote.status()) ?? .null
            let spec = CmuxDialogSpec(title: CmuxRemoteStrings.statusTitle, lines: CmuxRemoteStrings.statusLines(status),
                                      buttons: [CmuxDialogButton(id: "ok", title: CmuxRemoteStrings.done, role: .default)],
                                      identifier: "cmux.dialog.remote.status")
            guard let window else { return }
            CmuxDialogCenter.shared.present(spec, in: .window(window)) { _ in }
        }
    }

    /// `remote.confirm {action: share|access, on?, device?, scope?}`.
    static func methods(services: AppServices) -> [ControlMethod] {
        [
            .mainActor("remote.confirm") { [weak services] call in
                guard let services else { return .value(.null) }
                let action = call.params["action"]?.stringValue ?? ""
                let device = call.params["device"]?.stringValue ?? ""
                let scope = call.params["scope"]?.stringValue.flatMap(DeviceScope.init(rawValue:))
                guard action == "share" || (action == "access" && !device.isEmpty && scope != nil) else {
                    throw ControlError.invalidParams("action must be share, or access with device and scope (none, ask, view, full)")
                }
                guard let hub = services.macScreenPages.hub else { throw ControlError.invalidParams(CmuxRemoteStrings.signedOut) }
                let name = hub.devices.first { $0.id == device }?.name ?? device
                let (title, body) = action == "share" ? CmuxRemoteStrings.confirmShare()
                    : CmuxRemoteStrings.confirmAccess(device: name, scope: scope ?? .ask)
                let window = services.windows.active?.window ?? NSApp.keyWindow
                return .followUp {
                    guard await confirm(title: title, body: body, in: window).value else { return ["ok": false, "declined": true] }
                    try await apply(action, device: device, scope: scope, hub: hub)
                    return ["ok": true]
                }
            }.withDeadline(.fixed(.seconds(130))),
        ]
    }

    /// Makes the confirmed change with this app's full hub session.
    @MainActor static func apply(_ action: String, device: String, scope: DeviceScope?, hub: DeviceHub) async throws {
        if action == "share" {
            try await hub.setMacScreenShared(true)
            _ = try? await CmuxRemoteService.shared?.call("request", .object(["permission": .string("screen-recording")]))
        } else if let scope {
            try await hub.setPermission(host: hub.identity.id, viewer: device, scope: scope)
        }
    }

    /// The person's answer to one dialog (false without a window).
    @MainActor static func confirm(title: String, body: String, in window: NSWindow?) -> Task<Bool, Never> {
        Task { @MainActor in
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
}
