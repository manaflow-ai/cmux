import CMUXAgentLaunch
import CmuxAgentReplica
import CmuxAgentTruthKit
import Foundation

struct AgentGUIHookFactMapper {
    func hookFact(from event: WorkstreamEvent) -> HookFact {
        hookFact(
            sessionID: event.sessionId,
            rawHookName: event.hookEventName.rawValue,
            surfaceID: event.surfaceId,
            transcriptPath: event.transcriptPath,
            cwd: event.cwd,
            pid: event.ppid.map(Int32.init),
            source: event.source,
            toolInputJSON: event.toolInputJSON,
            extraFieldsJSON: event.extraFieldsJSON
        )
    }

    func hookFact(
        sessionID: String,
        rawHookName: String,
        surfaceID: String?,
        transcriptPath: String?,
        cwd: String?,
        pid: Int32?,
        source: String,
        toolInputJSON: String?,
        extraFieldsJSON: String?
    ) -> HookFact {
        HookFact(
            sessionID: AgentSessionID(rawValue: sessionID),
            eventName: HookEventName(rawValue: rawHookName),
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            cwd: cwd,
            pid: pid,
            notificationRequiresInput: notificationRequiresInput(rawHookName: rawHookName, toolInputJSON: toolInputJSON, extraFieldsJSON: extraFieldsJSON),
            hooksUnavailableSafeMode: boolField("hooks_unavailable_safe_mode", in: [toolInputJSON, extraFieldsJSON]),
            cliVersion: stringField("cli_version", in: [toolInputJSON, extraFieldsJSON]),
            minimumCLIVersion: stringField("minimum_cli_version", in: [toolInputJSON, extraFieldsJSON])
        )
    }

    func wrapperLaunchFact(from event: WorkstreamEvent) -> WrapperLaunchFact? {
        guard event.hookEventName == .sessionStart,
              stringField("wrapper_origin", in: [event.toolInputJSON, event.extraFieldsJSON]) == "cmux-wrapper",
              let surfaceID = event.surfaceId,
              let rawKind = stringField("agent_kind", in: [event.toolInputJSON, event.extraFieldsJSON]) ?? event.source.nilIfBlank,
              let pid = event.ppid.map(Int32.init),
              let cwd = event.cwd?.nilIfBlank else {
            return nil
        }
        return WrapperLaunchFact(
            surfaceID: surfaceID,
            agentKind: AgentKind(rawValue: rawKind),
            pid: pid,
            cwd: cwd,
            sessionID: event.sessionId.nilIfBlank.map(AgentSessionID.init(rawValue:)),
            launchArgvKind: launchArgvKind(in: [event.toolInputJSON, event.extraFieldsJSON]),
            socketWasDown: boolField("socket_was_down", in: [event.toolInputJSON, event.extraFieldsJSON]),
            hooksUnavailableSafeMode: boolField("hooks_unavailable_safe_mode", in: [event.toolInputJSON, event.extraFieldsJSON]),
            cliVersion: stringField("cli_version", in: [event.toolInputJSON, event.extraFieldsJSON]),
            minimumCLIVersion: stringField("minimum_cli_version", in: [event.toolInputJSON, event.extraFieldsJSON])
        )
    }

    private func launchArgvKind(in jsonStrings: [String?]) -> LaunchArgvKind {
        switch stringField("launch_argv_kind", in: jsonStrings) {
        case "resume": .resume
        default: .new
        }
    }

    private func notificationRequiresInput(rawHookName: String, toolInputJSON: String?, extraFieldsJSON: String?) -> Bool {
        if rawHookName == "PermissionRequest" || rawHookName == "AskUserQuestion" {
            return true
        }
        return boolField("requires_input", in: [toolInputJSON, extraFieldsJSON])
            || boolField("notification_requires_input", in: [toolInputJSON, extraFieldsJSON])
    }

    private func stringField(_ key: String, in jsonStrings: [String?]) -> String? {
        for json in jsonStrings {
            guard let object = jsonObject(json), let value = object[key] as? String, let trimmed = value.nilIfBlank else { continue }
            return trimmed
        }
        return nil
    }

    private func boolField(_ key: String, in jsonStrings: [String?]) -> Bool {
        for json in jsonStrings {
            guard let object = jsonObject(json) else { continue }
            if let value = object[key] as? Bool {
                return value
            }
            if let value = object[key] as? String {
                return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
            }
        }
        return false
    }

    private func jsonObject(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return nil
        }
        return object
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
