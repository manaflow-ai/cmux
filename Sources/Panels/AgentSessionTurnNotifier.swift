import CmuxSettings
import Foundation

/// Turns an agent session panel's provider events into classic agent
/// notifications: a finished turn posts like a Claude Code Stop hook, and a
/// provider that exits with a failure posts an error. They go through
/// `AgentNotificationDelivery`, so the panel gets the banner, Dock badge,
/// focused-pane suppression, click-to-jump and workspace mute that terminal
/// agents get. The panel's own surface is the target. Stopping the agent or
/// closing its panel is not a failure and posts nothing.
@MainActor
final class AgentSessionTurnNotifier {
    /// One notification for the panel's surface.
    struct Notice: Equatable {
        var workspaceID: UUID
        var surfaceID: UUID
        var provider: AgentSessionProviderID
        var title: String
        var subtitle: String
        var body: String
        var category: AgentNotifyCategory
        var correlationKey: String
    }

    typealias Deliver = (Notice) -> Void

    static let bodyLimit = 200
    /// The newest assistant text kept for the body; older text is dropped.
    private static let retainedTextLimit = 4_096

    private let surfaceID: UUID
    private let workspaceID: () -> UUID
    private let workingDirectory: () -> String?
    private let deliver: Deliver
    /// Assistant text of the turn in progress.
    private var turnText = ""
    /// The turn has had output or activity since its last notification, so a
    /// repeated completion signal for the same turn posts once.
    private var turnOpen = false
    private var turnCount = 0

    init(
        surfaceID: UUID,
        workspaceID: @escaping () -> UUID,
        workingDirectory: @escaping () -> String?,
        deliver: Deliver? = nil
    ) {
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        // Resolved here, on the main actor: a default argument is not.
        self.deliver = deliver ?? Self.deliverThroughAgentGate
    }

    func observe(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        let provider = (event["providerId"] as? String).flatMap(AgentSessionProviderID.init(rawValue:))
        let sessionID = event["sessionId"] as? String ?? ""
        switch type {
        case "provider.started":
            turnText = ""
            turnOpen = false
        case "provider.output":
            guard event["stream"] as? String == "stdout", let text = event["text"] as? String else { return }
            turnOpen = true
            turnText += text
            if turnText.count > Self.retainedTextLimit {
                turnText = String(turnText.suffix(Self.retainedTextLimit))
            }
        case "provider.activity":
            turnOpen = true
        case "provider.turnComplete":
            guard turnOpen, let provider else { return }
            turnOpen = false
            turnCount += 1
            let body = Self.body(turnText)
            turnText = ""
            deliver(Notice(
                workspaceID: workspaceID(), surfaceID: surfaceID, provider: provider,
                title: provider.displayName, subtitle: completedSubtitle(), body: body,
                category: .turnComplete, correlationKey: "agent-session:\(sessionID):turn:\(turnCount)"
            ))
        case "provider.exit":
            let status = (event["status"] as? NSNumber)?.int32Value ?? 0
            turnOpen = false
            turnText = ""
            // An agent the person stopped, or whose panel closed, exits on a signal: no error.
            guard status != 0, event["stopRequested"] as? Bool != true, let provider else { return }
            let body = String(
                format: String(localized: "agentSession.web.log.providerExitedFormat", defaultValue: "Provider exited %d"),
                Int(status)
            )
            deliver(Notice(
                workspaceID: workspaceID(), surfaceID: surfaceID, provider: provider,
                title: provider.displayName,
                subtitle: String(localized: "agent.generic.notification.subtitle.error", defaultValue: "Error"),
                body: body, category: .other, correlationKey: "agent-session:\(sessionID):exit"
            ))
        default:
            break
        }
    }

    /// "Completed in <project>" like the Claude Code Stop hook, else "Completed".
    private func completedSubtitle() -> String {
        let project = workingDirectory()
            .map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent }
            .flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        guard let project else {
            return String(localized: "agent.generic.notification.subtitle.completed", defaultValue: "Completed")
        }
        return String(
            format: String(localized: "agent.claude.completion.subtitle.completedInProject", defaultValue: "Completed in %@"),
            project
        )
    }

    /// The turn's last assistant message, collapsed to one line and cut to
    /// `bodyLimit` characters.
    static func body(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > bodyLimit else { return collapsed }
        return String(collapsed.prefix(bodyLimit - 1)) + "…"
    }

    /// The classic agent gate (`notifications.agentTurnComplete`, ...), with
    /// the provider as the agent for sound overrides and policy hooks.
    static let deliverThroughAgentGate: Deliver = { notice in
        let agent = notice.provider.rawValue
        _ = AgentNotificationDelivery().enqueue(
            workspaceID: notice.workspaceID,
            surfaceID: notice.surfaceID,
            title: notice.title,
            subtitle: notice.subtitle,
            body: notice.body,
            category: notice.category,
            pending: false,
            soundContext: NotificationSoundOverrideContext(
                agentID: agent,
                alertType: notice.category.soundAlertType ?? .errorStalled
            ),
            agentKind: agent,
            correlationKey: notice.correlationKey
        )
    }
}
