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
                // Only a run that awaits its work waits for the terminal.
                request.params["wait"]?.boolValue == true
                    && ((try? Self.resolveAction(request.params, in: snapshot.catalog))?.startsTerminal ?? false)
            }).withLimit { request, snapshot in
                // A network action the caller awaits (Connect to CodeRouter).
                guard request.params["wait"]?.boolValue == true,
                      (try? Self.resolveAction(request.params, in: snapshot.catalog))?.waitsForResult == true else { return nil }
                return ActionDescriptor.resultDeadline
            },
            .async("settings.get") { [weak self] call in
                guard let self else { throw Self.stopped }
                return try await self.settingsGet(call)
            },
            .async("settings.set") { [weak self] call in
                guard let self else { throw Self.stopped }
                let store = try self.settingsStore()
                let path = try Self.settingsPath(call.params, allowEmpty: false)
                guard let value = call.params["value"] else { throw ControlError.invalidParams(ControlStrings.format("control.error.missingParam", "%1$@ requires params.%2$@", "settings.set", "value")) }
                try await store.set(value, at: path)
                // Read-your-writes: answer from the file until the watcher republishes.
                self.snapshots.publish { $0.settings = nil }
                return ["path": .array(path.map(JSONValue.string)), "value": value, "file": .string(store.fileLocation)]
            },
            .async("settings.unset") { [weak self] call in
                guard let self else { throw Self.stopped }
                let store = try self.settingsStore()
                let path = try Self.settingsPath(call.params, allowEmpty: false)
                try await store.remove(path)
                self.snapshots.publish { $0.settings = nil }
                return ["path": .array(path.map(JSONValue.string)), "file": .string(store.fileLocation)]
            },
            .snapshot("snapshot.get") { call in
                let snapshot = call.snapshot
                return [
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
        let noun = params["noun"]?.stringValue?.lowercased().map(ControlCatalog.renamedCLIName)
        let availableOnly = params["available_only"]?.boolValue ?? false
        let actions = catalog.actions.filter { action in
            if let category, action.category.lowercased() != category { return false }
            if let noun, action.cliName.split(separator: " ").first.map(String.init) != noun { return false }
            if availableOnly, !catalog.isAvailable(action) { return false }
            return true
        }
        var categories: [String] = []
        var seen: Set<String> = []
        for action in catalog.actions where seen.insert(action.category).inserted { categories.append(action.category) }
        return [
            "actions": .array(actions.map(catalog.json)),
            "categories": .array(categories.map(JSONValue.string)),
            "count": JSONValue(actions.count),
        ]
    }

    // MARK: - action.run

    /// Runs the target resolver over the target and every target argument.
    private func resolvedTargets(_ request: ControlActionRequest, deadline: ContinuousClock.Instant) async throws -> ControlActionRequest {
        guard let resolver = targetResolver else { return request }
        var resolved = request
        if let target = request.target { resolved.target = try await resolver(target, deadline) }
        for (name, value) in request.arguments {
            if case .target(let ref) = value { resolved.arguments[name] = .target(try await resolver(ref, deadline)) }
        }
        return resolved
    }

    private func runAction(_ call: ControlCall) async throws -> JSONValue {
        let catalog = call.snapshot.catalog
        let action = try Self.resolveAction(call.params, in: catalog)
        let request = try await resolvedTargets(
            Self.validatedRequest(for: action, params: call.params, knownKinds: catalog.targetKinds), deadline: call.deadline)
        guard catalog.isAvailable(action, target: request.target) || action.unavailableReason != nil else {
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionNotAvailableInContext", "%@ is not available in the current context", action.id), data: [
                "action": .string(action.id), "requires": .array(action.requires.map(JSONValue.string)),
            ])
        }
        if action.isDestructive, request.arguments["confirm"] != .bool(true) {
            throw Self.confirmationRequired(action.id)
        }
        let executor = self.executor
        // `wait: true` answers after the daemon applied the work the handler
        // started (its command replies), within the request deadline.
        let wait = call.params["wait"]?.boolValue ?? false
        let run = try await workQueue.run(connection: call.connection, method: call.method, deadline: call.deadline) {
            wait ? executor.performActionTracked(request) : ControlActionRun(outcome: executor.performAction(request))
        }
        switch run.outcome {
        case .ran:
            if let failure = await Self.firstFailure(of: run.work) {
                throw Self.workError(failure, action: action.id, method: call.method)
            }
            var result: [String: JSONValue] = [
                "action": .string(action.id),
                "ran": true,
                "waited": .bool(wait),
                "args": .object(request.arguments.mapValues(\.json)),
            ]
            if let target = request.target { result["target"] = target.json }
            return .object(result)
        case .unknownAction:
            throw ControlError(code: "not_found", message: ControlStrings.format("control.error.unknownAction", "Unknown action '%@'", action.id))
        case .notBound:
            throw ControlError(code: "not_bound", message: ControlStrings.format("control.error.actionNotBound", "%@ has no handler in this build", action.id), data: ["action": .string(action.id)])
        case .unavailable:
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionNotAvailableInContext", "%@ is not available in the current context", action.id), data: ["action": .string(action.id)])
        case .disabled:
            throw ControlError(code: "disabled", message: ControlStrings.format("control.error.actionDisabled", "%@ is disabled right now", action.id), data: ["action": .string(action.id)])
        case .refused(let reason):
            throw ControlError(code: "unavailable", message: ControlStrings.format("control.error.actionUnavailableReason", "%1$@ unavailable: %2$@", action.id, reason), data: ["action": .string(action.id), "reason": .string(reason)])
        case .confirmationRequired:
            throw Self.confirmationRequired(action.id)
        }
    }

    /// The first failure among an action's work tasks, after all finished.
    static func firstFailure(of work: [ActionWork]) async -> ActionWorkFailure? {
        var failure: ActionWorkFailure?
        for task in work {
            if let error = await task.value { failure = failure ?? error }
        }
        return failure
    }

    /// The control error for failed action work. A terminal start that
    /// missed its deadline is a `timeout` that says the terminal may still
    /// appear; anything else is a `daemon_error`.
    static func workError(_ failure: ActionWorkFailure, action: String, method: String) -> ControlError {
        guard failure.terminalMayAppear else {
            return ControlError(code: "daemon_error", message: failure.message, data: ["action": .string(action)])
        }
        var error = ControlError.terminalStartTimeout(method, after: TerminalStartDeadline.daemon)
        if case .object(var members) = error.data {
            members["action"] = .string(action)
            members["detail"] = .string(failure.message)
            error.data = .object(members)
        }
        return error
    }

    /// Typed refusal for a destructive action run without `confirm: true`.
    static func confirmationRequired(_ id: String) -> ControlError {
        ControlError(code: "confirmation_required", message: ActionRegistry.confirmationRequiredReason(forRawID: id),
                     data: ["action": .string(id), "argument": .string(ActionArgument.confirmName)])
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

    private func settingsStore() throws -> any ControlSettingsStore {
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
