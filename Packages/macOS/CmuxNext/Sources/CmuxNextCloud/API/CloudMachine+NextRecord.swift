public import CmuxNextDaemon
import Foundation

extension CloudMachine {
    /// A `CloudMachine` record of the cmux-next backend (contract 1.2), as
    /// the Cloud app server answers it.
    public init?(next value: JSONValue) {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        // The in-between states stay their own (cloud-machine-ops.ts CloudMachineStatus): a
        // pausing machine is not paused yet, and a deleting one is not gone.
        let status: Status = switch value["status"]?.stringValue {
        case "provisioning": .provisioning
        case "starting": .starting
        case "running": .running
        case "pausing": .pausing
        case "paused": .paused
        case "deleting": .deleting
        case "failed": .failed
        default: .unknown
        }
        // `capabilities` is the older guest/session name list (`agent_session`,
        // `terminal`, ...), not a provider feature gate. Only the dedicated
        // provider-operation field is mapped to action capabilities; this
        // preserves old records while allowing newer backends to gate actions.
        let providerRaw = value["provider_operations"] ?? value["providerOperations"] ?? value["provider_capabilities"]
        let capabilities: CloudMachine.Capabilities? = providerRaw.flatMap { raw in
            if case let .array(names) = raw {
                return CloudMachine.Capabilities(names: names.compactMap(\.stringValue))
            }
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(CloudMachine.Capabilities.self, from: data)
        }
        // The idle auto-pause fields, when the backend sends them (`/api/vm` names).
        let minutes = (value["idlePauseMinutes"]?.doubleValue).flatMap { Int(exactly: $0) }
            ?? Self.nextIdlePolicyMinutes(value["idle_policy"] ?? value["idlePolicy"])
        let idlePause = Self.idlePauseDiagnostics(value["idlePause"])
        self.init(id: id, provider: "cmux-next", status: status, displayName: value["name"]?.stringValue,
                  capabilities: capabilities,
                  pauseReason: Self.nextPauseReason(value["pause_reason"] ?? value["pauseReason"]), idlePauseMinutes: minutes,
                  idlePause: idlePause, lastChangeFailure: Self.changeFailure(value["error"]))
        serverRevision = value["revision"]?.stringValue
        createdBy = value["creator"]?.stringValue
    }

    /// The backend's `pause_reason` (`pauseReason` from an older app server): why cmux paused the
    /// machine by itself. `idle` and the cost backstop `no_report` are both cmux's own idle pause,
    /// which an attach resumes; a VM stopped from inside (`provider_stopped`, `provider_paused`)
    /// and a person's pause (null) carry no reason the app shows.
    public static func nextPauseReason(_ value: JSONValue?) -> PauseReason? {
        switch value?.stringValue {
        case "idle", "no_report": .idle
        case "user": .user
        default: nil
        }
    }

    /// The app-server contract uses seconds in `idle_policy`; preserve the
    /// CloudMachine minute model used by legacy API records.
    public static func nextIdlePolicyMinutes(_ value: JSONValue?) -> Int? {
        guard let value, case let .object(fields) = value,
              let seconds = fields["idle_seconds"]?.doubleValue else { return nil }
        return Int(exactly: seconds / 60)
    }

    /// The backend's `error` (`{code, message, at}`): why the last pause, resume or resize failed
    /// after the server answered it. Nil for null or a shape this client does not read.
    public static func changeFailure(_ value: JSONValue?) -> ChangeFailure? {
        guard let value, case let .object(fields) = value, let code = fields["code"]?.stringValue, !code.isEmpty else { return nil }
        let at = fields["at"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        return ChangeFailure(code: code, message: fields["message"]?.stringValue ?? "", at: at)
    }

    private static func idlePauseDiagnostics(_ value: JSONValue?) -> IdlePauseDiagnostics? {
        guard let value, case let .object(fields) = value,
              let minutes = fields["minutes"]?.doubleValue.flatMap({ Int(exactly: $0) }),
              let privateAddressKnown = fields["privateAddressKnown"]?.boolValue else { return nil }
        let integer: (String, [String: JSONValue]) -> Int? = { key, object in
            object[key]?.doubleValue.flatMap { Int(exactly: $0) }
        }
        let lastDecision: IdlePauseDiagnostics.LastDecision? = fields["lastDecision"].flatMap { value in
            guard case let .object(decision) = value else { return nil }
            guard let at = integer("at", decision), let outcome = decision["outcome"]?.stringValue,
                  let reason = decision["reason"]?.stringValue,
                  let runValue = decision["run"], case let .object(runFields) = runValue,
                  let checked = integer("checked", runFields), let elapsedMs = integer("elapsedMs", runFields) else { return nil }
            return .init(at: at, outcome: outcome, reason: reason, run: .init(checked: checked, elapsedMs: elapsedMs))
        }
        return .init(minutes: minutes, lastCheckedAt: integer("lastCheckedAt", fields),
                     idleSince: integer("idleSince", fields), lastApiActivityAt: integer("lastApiActivityAt", fields),
                     privateAddressKnown: privateAddressKnown, lastDecision: lastDecision)
    }
}
