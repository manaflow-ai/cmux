import Foundation

extension CMUXCLI {
    func summarizeCampfireObserverNotification(
        def: AgentHookDef,
        object: [String: Any]
    ) -> AgentHookNotificationSummary? {
        guard def.name == "campfire" else { return nil }
        let extra = (object["extra"] as? [String: Any]) ?? [:]
        let eventType = firstString(in: object, keys: ["campfire_event_type", "campfireEventType"])
            ?? firstString(in: extra, keys: ["campfire_event_type", "campfireEventType"])
        guard let eventType else { return nil }
        let displayName = firstString(in: object, keys: ["display_name", "displayName"])
            ?? firstString(in: extra, keys: ["display_name", "displayName"])
        switch eventType {
        case "join.requested":
            let name = displayName ?? String(
                localized: "agent.campfire.notification.participantFallback",
                defaultValue: "Someone"
            )
            let body = String.localizedStringWithFormat(
                String(
                    localized: "agent.campfire.notification.body.joinRequested",
                    defaultValue: "%@ is waiting to join the Campfire session"
                ),
                name
            )
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.waiting", defaultValue: "Waiting"),
                body: truncate(body, maxLength: 180),
                status: .needsInput,
                isFallback: false,
                notifyCategory: .needsPermission
            )
        case "permission.asked":
            let name = displayName ?? String(
                localized: "agent.campfire.notification.participantFallback",
                defaultValue: "Someone"
            )
            let capability = firstString(in: object, keys: ["capability"])
                ?? firstString(in: extra, keys: ["capability"])
            let body = String.localizedStringWithFormat(
                String(
                    localized: "agent.campfire.notification.body.permissionAsked",
                    defaultValue: "%1$@ asked for permission to %2$@"
                ),
                name,
                campfireCapabilityLabel(capability)
            )
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.permission", defaultValue: "Permission"),
                body: truncate(body, maxLength: 180),
                status: .needsInput,
                isFallback: false,
                notifyCategory: .needsPermission
            )
        case "relay.error":
            return AgentHookNotificationSummary(
                subtitle: String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error"),
                body: String(
                    localized: "agent.campfire.notification.body.relayError",
                    defaultValue: "Campfire relay connection failed"
                ),
                status: .error,
                isFallback: false,
                notifyCategory: .other
            )
        default:
            return nil
        }
    }

    private func campfireCapabilityLabel(_ capability: String?) -> String {
        switch capability {
        case "queue:add":
            return String(localized: "agent.campfire.capability.queueAdd", defaultValue: "queue a prompt")
        case "queue:run-now":
            return String(localized: "agent.campfire.capability.queueRunNow", defaultValue: "run a prompt now")
        case "session:interrupt":
            return String(localized: "agent.campfire.capability.sessionInterrupt", defaultValue: "interrupt the agent")
        case "shell:exec":
            return String(localized: "agent.campfire.capability.shellExec", defaultValue: "run a shell command")
        case "tools:contribute":
            return String(localized: "agent.campfire.capability.toolsContribute", defaultValue: "add tools or skills")
        case "files:list":
            return String(localized: "agent.campfire.capability.filesList", defaultValue: "browse files")
        default:
            return String(localized: "agent.campfire.capability.fallback", defaultValue: "do something")
        }
    }
}
