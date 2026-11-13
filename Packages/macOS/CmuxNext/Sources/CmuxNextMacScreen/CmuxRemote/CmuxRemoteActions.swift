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
    public var screenHost: MacScreenHubHost
    public var hub: @MainActor () -> DeviceHub?
    public var window: @MainActor () -> NSWindow?
    public var openDevices: @MainActor () -> Void

    public init(remote: CmuxRemoteService, screenHost: MacScreenHubHost, hub: @escaping @MainActor () -> DeviceHub?, window: @escaping @MainActor () -> NSWindow?,
                openDevices: @escaping @MainActor () -> Void) {
        self.remote = remote
        self.screenHost = screenHost
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
        _ = registry.bindEffect("macScreen.shareThisMac", unavailable: { environment.hub() == nil ? CmuxRemoteStrings.signedOut : nil }, effect: { _ in
            guard environment.hub() != nil else { return .refused(CmuxRemoteStrings.signedOut) }
            guard let window = environment.window() else { return .refused(L.t("macScreen.setup.noWindow", "Open a cmux window to share this Mac.")) }
            return CmuxRemoteSharingSetup(host: environment.screenHost).begin(in: window)
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
        for id: ActionID in ["macScreen.stopSharing", "remote.stopScreenSession"] {
            _ = registry.bindEffect(id, unavailable: { environment.screenHost.noSessionReason }, effect: { _ in
                environment.screenHost.stopSession(immediately: true)
                return .done
            })
        }
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
                return .followUp {
                    if action == "share" {
                        guard let window else { return ["ok": false, "declined": true] }
                        let shared = try await CmuxRemoteSharingSetup(host: environment.screenHost).confirm(in: window)
                        return ["ok": .bool(shared), "declined": .bool(!shared)]
                    }
                    let (title, body) = CmuxRemoteStrings.confirmAccess(device: name, scope: scope ?? .ask)
                    guard await Self.confirm(title: title, body: body, in: window) else { return ["ok": false, "declined": true] }
                    try await Self.applyAccess(device: device, scope: scope, hub: hub)
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
