public import CmuxNextSettings
import CmuxNextActions
import Foundation

/// The router's own methods. Reads use the snapshot lane; `action.run`
/// validates off the main actor and runs only the handler through the work
/// queue; settings writes go to the settings file actor.
extension ControlRouter {
    func builtinMethods() -> [ControlMethod] {
        [
            .snapshot("system.ping") { [identity] _ in
                ["pong": true, "app": .string(identity.appName), "protocol_version": JSONValue(Self.protocolVersion)]
            },
            .snapshot("system.identify") { [weak self] _ in
                guard let self else { throw Self.stopped }
                return self.identify()
            },
            .snapshot("system.capabilities") { [weak self] _ in
                guard let self else { throw Self.stopped }
                return ["protocol_version": JSONValue(Self.protocolVersion), "methods": .array(self.methodNames.map(JSONValue.string))]
            },
            .snapshot("action.list") { call in Self.list(call.params, catalog: call.snapshot.catalog) },
            .snapshot("action.describe") { call in
                let catalog = call.snapshot.catalog
                return ["action": catalog.json(try Self.resolveAction(call.params, in: catalog))]
            },
            .async("action.run") { [weak self] call in
                guard let self else { throw Self.stopped }
                return try await self.runAction(call)
            }.withDeadline(.perRequest { request, snapshot in
                // Only a run that awaits its work (the default) waits for the terminal.
                (request.params["wait"]?.boolValue ?? true)
                    && ((try? Self.resolveAction(request.params, in: snapshot.catalog))?.startsTerminal ?? false)
            }).claimingProgress().withLimit { request, snapshot in
                // A network action the caller awaits (Connect to CodeRouter).
                guard request.params["wait"]?.boolValue == true,
                      (try? Self.resolveAction(request.params, in: snapshot.catalog))?.waitsForResult == true else { return nil }
                return ActionDescriptor.resultDeadline
            },
            // `cmux tab <id> focus` (state-ownership.md 3): runs the
            // `tab.focus` action on the tab, with action.run's contract.
            .async("tab.focus") { [weak self] call in
                guard let self else { throw Self.stopped }
                guard let tab = (call.params["tab"] ?? call.params["id"])?.stringValue, !tab.isEmpty else {
                    throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", "tab.focus", "tab"))
                }
                var params = call.params
                params["tab"] = nil
                params["id"] = nil
                params["cli"] = nil
                params["action"] = "tab.focus"
                params["target"] = .string("tab:" + tab)
                let request = ControlRequest(id: call.request.id, method: call.method, params: params)
                return try await self.runAction(ControlCall(request: request, snapshot: call.snapshot, connection: call.connection,
                                                            deadline: call.deadline, progress: call.progress))
            }.claimingProgress(),
            .async("settings.get") { [weak self] call in
                guard let self else { throw Self.stopped }
                return try await self.settingsGet(call)
            },
            .async("settings.set") { [weak self] call in
                guard let self else { throw Self.stopped }
                let store = try self.settingsStore()
                let path = try Self.settingsPath(call.params, allowEmpty: false)
                guard let value = call.params["value"] else { throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", "settings.set", "value")) }
                try await self.writeSetting(value, at: path, store: store, call: call)
                return ["path": .array(path.map(JSONValue.string)), "value": value, "file": .string(store.fileLocation)]
            }.withDeadline(.fixed(.seconds(120))), // `confirm: true` waits for the person on a native sheet
        ] + ["settings.reset", "settings.unset"].map { name in
            ControlMethod.async(name) { [weak self] call in
                guard let self else { throw Self.stopped }
                let store = try self.settingsStore()
                let path = try Self.settingsPath(call.params, allowEmpty: false)
                try await self.writeSetting(nil, at: path, store: store, call: call)
                return ["path": .array(path.map(JSONValue.string)), "file": .string(store.fileLocation)]
            }.withDeadline(.fixed(.seconds(120))) // `confirm: true` waits for the person, as settings.set
        } + [
            .snapshot("snapshot.get") { call in
                let snapshot = call.snapshot
                return [
                    "sequence": JSONValue.number(Double(snapshot.topology.daemonSequence)),
                    "generation": JSONValue(Int(truncatingIfNeeded: snapshot.generation)),
                    "published_uptime_ns": .number(Double(snapshot.publishedAtUptimeNanos)),
                    "tab_count": JSONValue(snapshot.topology.tabCount),
                    "topology": snapshot.topology.json,
                ]
            },
        ] + diagnosticMethods()
    }

    static let stopped = ControlError(code: "unavailable", message: ControlStrings.text("control.error.routerStopped", "the control router stopped"))

    private func identify() -> JSONValue {
        let transport = transportInfo
        return [
            "app": .string(identity.appName),
            "version": .string(identity.version),
            "build": .string(identity.build),
            "bundle_id": identity.bundleID.map(JSONValue.string) ?? .null,
            "tag": identity.tag.map(JSONValue.string) ?? .null,
            "pid": JSONValue(Int(identity.processID)),
            "socket_path": transport.socketPath.map(JSONValue.string) ?? .null,
            "access_mode": transport.accessMode.map(JSONValue.string) ?? .null,
            "protocol_version": JSONValue(Self.protocolVersion),
            "methods": .array(methodNames.map(JSONValue.string)),
        ]
    }

    static func list(_ params: [String: JSONValue], catalog: ControlCatalog) -> JSONValue {
        let category = params["category"]?.stringValue?.lowercased()
        let noun = params["noun"]?.stringValue.map { ControlCatalog.renamedCLIName($0.lowercased()) }
        let availableOnly = params["available_only"]?.boolValue ?? false
        let actions = catalog.actions.filter { action in
            if action.disabledFeature != nil { return false }
            if let category, action.category.lowercased() != category { return false }
            if let noun, action.cliName.split(separator: " ").first.map(String.init) != noun { return false }
            if availableOnly, !catalog.isAvailable(action) { return false }
            return true
        }
        var categories: [String] = []
        var seen: Set<String> = []
        for action in catalog.actions where action.disabledFeature == nil && seen.insert(action.category).inserted { categories.append(action.category) }
        return [
            "actions": .array(actions.map(catalog.json)),
            "categories": .array(categories.map(JSONValue.string)),
            "count": JSONValue(actions.count),
        ]
    }

    // MARK: - action.run (ControlRouter+ActionRun)

    /// The first failure among an action's work tasks, after all finished.
    static func firstFailure(of work: [ActionWork]) async -> ActionWorkFailure? {
        var failure: ActionWorkFailure?
        for task in work {
            if let error = await task.value { failure = failure ?? error }
        }
        return failure
    }

    // MARK: - settings

    /// Answers from the published cmux.json snapshot when there is one (no
    /// file IO); otherwise reads through the settings file actor.
    private func settingsGet(_ call: ControlCall) async throws -> JSONValue {
        let path = try Self.settingsPath(call.params, allowEmpty: true)
        let value: JSONValue?
        let file: String
        if let root = call.snapshot.settings {
            value = path.isEmpty ? root : root.value(at: path)
            file = settings?.fileLocation ?? ""
        } else {
            let store = try settingsStore()
            value = try await store.value(at: path)
            file = store.fileLocation
        }
        return ["path": .array(path.map(JSONValue.string)), "exists": .bool(value != nil), "value": value ?? .null, "file": .string(file)]
    }

    func settingsStore() throws -> any ControlSettingsStore {
        guard let settings else { throw ControlError(code: "unavailable", message: ControlStrings.text("control.error.settingsUnavailable", "settings are not available")) }
        return settings
    }

    static func settingsPath(_ params: [String: JSONValue], allowEmpty: Bool) throws -> [String] {
        let path: [String]
        switch params["path"] ?? params["key"] {
        case .string(let dotted): path = CmuxConfigFile.keyPath(from: dotted)
        case .array(let items):
            let keys = items.compactMap(\.stringValue)
            guard keys.count == items.count else { throw ControlError.invalidParams(ControlStrings.text("control.error.pathArrayStrings", "path array must contain strings")) }
            path = keys
        case nil, .null: path = []
        default: throw ControlError.invalidParams(ControlStrings.text("control.error.pathShape", "path must be a dotted string or an array of keys"))
        }
        guard allowEmpty || !path.isEmpty else { throw ControlError.invalidParams(ControlStrings.text("control.error.pathRequired", "path is required")) }
        guard !path.contains(where: \.isEmpty) else { throw ControlError.invalidParams(ControlStrings.text("control.error.pathEmptyKey", "path has an empty key")) }
        return path
    }
}
