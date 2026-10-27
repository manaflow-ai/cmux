public import CmuxNextControl
#if DEBUG
import CmuxNextDevices
import CmuxNextSettings
import Foundation

/// `debug.device_hub` (development builds): the device hub as Mac Screen and
/// Settings > Devices see it, and its intents, for live checks. Never a
/// secret: no account session, ticket, relay secret or signature in params,
/// results or logs. A relay secret moves only through a file readable by
/// this user (mode 0600).
/// - `state` (default): status, connection, plan, this device, devices
///   (id, name, platform, online, shared, fingerprint), permissions of this
///   Mac and of the hosts read so far, pending requests (id, viewer, scope),
///   session tickets (id, role, scope, peer), this Mac's hub session and
///   menu bar title, the prompt's request, relays (id, name, enabled,
///   priority, has_secret), audit count, last error, and each device tab's
///   phase and View Only.
/// - `connect` {device, scope?}: opens the device in a new Mac Screen tab and
///   asks for `scope` (view or full) as a person's click would; no scope:
///   the Connect card.
/// - `request` {device, scope}: asks the hub directly (no tab).
/// - `decide` {session, choice}: the approval prompt's buttons
///   (deny, once, always_view, always_full).
/// - `set_permission` {viewer, scope, host?}: host defaults to this Mac.
/// - `set_shared` {shared}: Allow Mac Screen on this Mac.
/// - `rename` {device, name}, `remove` {device}.
/// - `end` {session, reason?}; `stop_sharing`; `revoke_viewer`.
/// - `relay_add` {name, urls, mode, secret_file, enabled?, priority?, id?}:
///   `secret_file` holds `{"secret":…}` or `{"username":…,"password":…}`.
/// - `relay_delete` {id}; `relay_check` {id}.
/// - `refresh`: devices, permissions, relays and the audit log again.
/// - `audit` {limit?}: the newest entries as History shows them.
extension MacScreenPages {
    public func registerDeviceHubDebug(on router: ControlRouter?, settings: MacScreenDevicesSettings?,
                                openTab: @escaping @MainActor (MacScreenRecord, String?) -> String?) {
        router?.register([
            .async("debug.device_hub") { [weak self] call in
                guard let self else { return .null }
                return await deviceHubDebug(call.params, settings: settings, openTab: openTab)
            },
        ])
    }

    func deviceHubDebug(_ params: [String: JSONValue], settings: MacScreenDevicesSettings?,
                        openTab: @MainActor (MacScreenRecord, String?) -> String?) async -> JSONValue {
        let action = params["action"]?.stringValue ?? "state"
        if action == "state" { return hubState }
        guard let hub else { return ["error": "not signed in to a device hub"] }
        func scope(_ key: String) -> SessionScope? { params[key]?.stringValue.flatMap(SessionScope.init(rawValue:)) }
        func fail(_ error: any Error) -> JSONValue { ["error": .string((error as? DeviceHubError)?.description ?? "\(error)")] }
        do {
            switch action {
            case "connect":
                guard let device = params["device"]?.stringValue.flatMap(MacScreenRecord.normalizedDeviceID) else { return ["error": "device required"] }
                if let scope = scope("scope") { pendingScopes[device] = scope }
                if let error = openTab(MacScreenRecord(deviceID: device), params["pane"]?.stringValue) { return ["error": .string(error)] }
                return ["opened": .string(MacScreenRecord(deviceID: device).url.absoluteString)]
            case "request":
                guard let device = params["device"]?.stringValue, let scope = scope("scope") else { return ["error": "device and scope required"] }
                let session = try await hub.requestSession(host: device, scope: scope)
                return ["session": .string(session.id), "state": session.state.map { .string($0.rawValue) } ?? .null]
            case "decide":
                guard let id = params["session"]?.stringValue, let request = hub.pendingRequests.first(where: { $0.id == id }) else {
                    return ["error": "no pending request with that session"]
                }
                let choices: [String: MacScreenApprovalChoice] = ["deny": .deny, "once": .once, "always_view": .alwaysView, "always_full": .alwaysFull]
                guard let choice = params["choice"]?.stringValue.flatMap({ choices[$0] }) else { return ["error": "choice: deny, once, always_view, always_full"] }
                let (decision, sessionScope, then) = choice.answer(requested: request.scope)
                try await hub.decide(request, decision: decision, scope: sessionScope)
                if let then { try await hub.setPermission(host: hub.identity.id, viewer: request.viewerId, scope: then) }
                return ["decided": .string(choice.rawValue)]
            case "set_permission":
                guard let viewer = params["viewer"]?.stringValue, let value = params["scope"]?.stringValue,
                      let access = MacScreenAccess(value: value) else { return ["error": "viewer and scope (none, ask, view, full) required"] }
                try await hub.setPermission(host: params["host"]?.stringValue ?? hub.identity.id, viewer: viewer, scope: access.scope)
                return hubState
            case "set_shared":
                guard let shared = params["shared"]?.boolValue else { return ["error": "shared required"] }
                try await hubHost.setSharing(shared)
                return hubState
            case "rename":
                guard let device = params["device"]?.stringValue, let name = params["name"]?.stringValue else { return ["error": "device and name required"] }
                return await settingsRun(settings, ["action": "rename", "id": .string(device), "name": .string(name)])
            case "remove":
                guard let device = params["device"]?.stringValue else { return ["error": "device required"] }
                return await settingsRun(settings, ["action": "remove", "id": .string(device)])
            case "end":
                guard let id = params["session"]?.stringValue else { return ["error": "session required"] }
                try await hub.endSession(id, reason: params["reason"]?.stringValue ?? MacScreenHubReason.viewerDisconnected.rawValue)
                return ["ended": .string(id)]
            case "stop_sharing":
                hubHost.stopSession()
                return hubState
            case "revoke_viewer":
                hubHost.revokeViewer()
                return hubState
            case "relay_add":
                guard let path = params["secret_file"]?.stringValue,
                      let data = await Task.detached(operation: { try? Data(contentsOf: URL(filePath: path)) }).value,
                      let secret = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return ["error": "secret_file must name a readable JSON file"]
                }
                let urls = params["urls"]?.arrayValue?.compactMap(\.stringValue) ?? params["urls"]?.stringValue.map { [$0] } ?? []
                var draft: [String: JSONValue] = [
                    "name": .string(params["name"]?.stringValue ?? "Relay"), "urls": .array(urls.map(JSONValue.string)),
                    "mode": .string(params["mode"]?.stringValue ?? (secret["secret"] != nil ? "shared_secret" : "static")),
                    "enabled": .bool(params["enabled"]?.boolValue ?? true), "priority": .number(Double(params["priority"]?.intValue ?? 0)),
                ]
                for key in ["secret", "username", "password"] { if let value = secret[key] { draft[key] = .string(value) } }
                if let id = params["id"]?.stringValue { draft["id"] = .string(id) }
                return await settingsRun(settings, ["action": "saveRelay", "relay": .object(draft)])
            case "relay_delete":
                guard let id = params["id"]?.stringValue else { return ["error": "id required"] }
                return await settingsRun(settings, ["action": "deleteRelay", "id": .string(id)])
            case "relay_check":
                guard let id = params["id"]?.stringValue else { return ["error": "id required"] }
                return await settingsRun(settings, ["action": "checkRelay", "id": .string(id)])
            case "refresh":
                await hub.refreshAll()
                await hub.refreshAudit()
                return hubState
            case "audit":
                await hub.refreshAudit(limit: params["limit"]?.intValue ?? 50)
                let names = store.deviceNames.merging(hub.devices.map { ($0.id, $0.name) }) { _, listed in listed }
                let rows = hub.audit.map { MacScreenDevicesSettings.historyRow($0, names: names, me: hub.identity.id) }
                return ["entries": Self.json(rows)]
            default:
                return ["error": "unknown action"]
            }
        } catch {
            return fail(error)
        }
    }

    private func settingsRun(_ settings: MacScreenDevicesSettings?, _ params: [String: JSONValue]) async -> JSONValue {
        guard let settings else { return ["error": "no Settings > Devices"] }
        do {
            let data = try JSONSerialization.data(withJSONObject: JSONValue.object(params).foundationObject)
            let run = try JSONDecoder().decode(MacScreenDevicesSettings.Run.self, from: data)
            return Self.json(await settings.run(run))
        } catch {
            return ["error": .string("\(error)")]
        }
    }

    static func json(_ value: some Encodable) -> JSONValue {
        (try? JSONValue.parse(JSONEncoder().encode(value))) ?? .null
    }

    private var hubState: JSONValue {
        let tabsRows: [JSONValue] = tabs.values.sorted { $0.key < $1.key }.compactMap { tab in
            guard let device = tab.record.deviceID, let pane = tab.pane, let viewer = pane.model.hub else { return nil }
            return ["tab": .string(tab.key), "device": .string(device), "phase": .string("\(viewer.phase)"),
                    "view_only": .bool(pane.model.viewOnly), "card": pane.model.card.map { .string("\($0)") } ?? .null]
        }
        guard let hub else {
            return ["configured": .bool(hubConfigured), "signed_in": .bool(false), "tabs": .array(tabsRows)]
        }
        let me = hub.identity.id
        let devices: [JSONValue] = hub.devices.map { device in
            ["id": .string(device.id), "name": .string(device.name), "platform": device.platform.map { .string($0.rawValue) } ?? .null,
             "online": .bool(device.online), "shared": .bool(device.macScreenShared), "this": .bool(device.id == me),
             "fingerprint": device.fingerprint.map(JSONValue.string) ?? .null]
        }
        var permissions: [String: JSONValue] = [:]
        for (host, list) in hub.permissions {
            permissions[host] = .object(Dictionary(list.map { ($0.viewerId, JSONValue.string($0.scope.rawValue)) }, uniquingKeysWith: { first, _ in first }))
        }
        let session: JSONValue = hubHost.session.map { session in
            ["id": .string(session.id), "viewer": .string(session.viewerID), "viewer_name": .string(session.viewerName),
             "scope": .string(session.scope.rawValue), "connected": .bool(session.connected)]
        } ?? .null
        return [
            "configured": .bool(hubConfigured), "signed_in": .bool(true),
            "status": .string("\(hub.status)"), "connection": .string("\(hub.connection)"),
            "plan": hub.me.map { .string($0.plan.rawValue) } ?? .null,
            "this_device": .string(me), "fingerprint": .string(DeviceIdentity.displayFingerprint(hub.identity.fingerprint)),
            "devices": .array(devices), "permissions": .object(permissions),
            "pending_requests": .array(hub.pendingRequests.map { ["id": .string($0.id), "viewer": .string($0.viewerId),
                                                                  "viewer_name": .string($0.viewerName), "scope": .string($0.scope.rawValue)] }),
            "tickets": .array(hub.tickets.values.sorted { $0.sessionId < $1.sessionId }.map {
                ["session": .string($0.sessionId), "role": .string($0.role.rawValue), "scope": .string($0.scope.rawValue),
                 "peer": .string($0.peer.id), "ice_servers": .number(Double($0.ice.count))]
            }),
            "sharing": .bool(hubHost.isSharing), "host_session": session,
            "indicator": hubHost.indicatorTitle.map(JSONValue.string) ?? .null,
            "prompt": approval.current.map { .string($0.id) } ?? .null,
            "relays": .array(hub.relays.map { ["id": .string($0.id), "name": .string($0.name), "enabled": .bool($0.enabled),
                                               "priority": .number(Double($0.priority)), "mode": .string($0.authMode.rawValue),
                                               "urls": .number(Double($0.urls.count)), "has_secret": .bool(hub.relaySecret($0.id) != nil)] }),
            "audit_count": .number(Double(hub.audit.count)),
            "last_error": hub.lastError.map { .string($0.description) } ?? .null,
            "tabs": .array(tabsRows),
        ]
    }
}
#else
extension MacScreenPages {
    public func registerDeviceHubDebug(on router: ControlRouter?, settings: MacScreenDevicesSettings?,
                                openTab: @escaping @MainActor (MacScreenRecord, String?) -> String?) {}
}
#endif
