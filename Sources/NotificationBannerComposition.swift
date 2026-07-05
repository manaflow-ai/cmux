import CMUXAgentLaunch
import CmuxFoundation
import Foundation

struct NotificationBannerContent: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String
}

enum NotificationBannerComposer {
    static nonisolated func composeNotificationBannerContent(
        title: String,
        subtitle: String,
        body: String,
        agentId: String?,
        workspaceTitle: String?,
        appName: String
    ) -> NotificationBannerContent {
        // Banner text leaves the app (Notification Center, lock screen, custom
        // notification commands), so redact the free-text body for every
        // producer here, at the single materialization point.
        let body = notificationBannerScrubber.scrub(body)
        let legacyTitle = title.isEmpty ? (notificationBannerNonEmpty(appName) ?? "cmux") : title
        let agentTitle = notificationBannerNonEmpty(title) ?? notificationBannerNonEmpty(appName) ?? "cmux"
        let workspace = notificationBannerNonEmpty(workspaceTitle)
        let originalSubtitle = notificationBannerNonEmpty(subtitle)

        if agentId != nil, let workspace {
            let subtitlePieces = [agentTitle, originalSubtitle].compactMap { $0 }
            return NotificationBannerContent(
                title: workspace,
                subtitle: subtitlePieces.joined(separator: " · "),
                body: body
            )
        }

        if agentId == nil,
           let workspace,
           originalSubtitle == nil,
           workspace != notificationBannerNonEmpty(legacyTitle) {
            return NotificationBannerContent(title: legacyTitle, subtitle: workspace, body: body)
        }

        return NotificationBannerContent(title: legacyTitle, subtitle: subtitle, body: body)
    }

    static nonisolated func composeFeedNotificationContent(
        hookEventName: WorkstreamEvent.HookEventName,
        source: String,
        toolName: String?,
        toolInputJSON: String?,
        workspaceTitle: String?
    ) -> NotificationBannerContent? {
        let sourceDisplayName = feedNotificationSourceDisplayName(source)
        let title: String
        let fallbackTitle: String
        let kind: String
        let body: String

        switch hookEventName {
        case .permissionRequest:
            fallbackTitle = String.localizedStringWithFormat(
                String(localized: "feed.notification.permission.title", defaultValue: "%@ permission"),
                sourceDisplayName
            )
            kind = String(localized: "feed.notification.permission.kind", defaultValue: "permission")
            body = feedNotificationPermissionBody(toolName: toolName, toolInputJSON: toolInputJSON)
        case .exitPlanMode:
            fallbackTitle = String.localizedStringWithFormat(
                String(localized: "feed.notification.exitPlan.title", defaultValue: "%@ plan ready"),
                sourceDisplayName
            )
            kind = String(localized: "feed.notification.exitPlan.kind", defaultValue: "plan ready")
            body = feedNotificationExitPlanBody(toolInputJSON: toolInputJSON)
        case .askUserQuestion:
            fallbackTitle = String.localizedStringWithFormat(
                String(localized: "feed.notification.question.title", defaultValue: "%@ question"),
                sourceDisplayName
            )
            kind = String(localized: "feed.notification.question.kind", defaultValue: "question")
            body = feedNotificationQuestionBody(toolInputJSON: toolInputJSON)
        default:
            return nil
        }

        if let workspace = notificationBannerNonEmpty(workspaceTitle) {
            title = workspace
        } else {
            title = fallbackTitle
        }

        // Feed bodies quote raw tool input (shell commands, question text),
        // which can embed tokens or URL credentials. Native banners escape the
        // app (Notification Center, lock screen), so scrub before composing.
        return NotificationBannerContent(
            title: title,
            subtitle: [sourceDisplayName, kind].compactMap(notificationBannerNonEmpty).joined(separator: " · "),
            body: notificationBannerScrubber.scrub(body)
        )
    }

    static nonisolated func notificationBannerSnippet(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        // Redact BEFORE truncating: a credential straddling the length
        // boundary would otherwise be cut mid-pattern and leak a partial
        // secret the scrubber can no longer match.
        let normalized = notificationBannerScrubber.scrub(value)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard maxLength > 3, normalized.count > maxLength else { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: maxLength - 3)
        return String(normalized[..<end]) + "..."
    }

    static nonisolated func assistantMessageSnippetRejectingJSONBlob(_ value: String?, maxLength: Int) -> String? {
        guard let value, !isJSONBlobAssistantMessage(value) else { return nil }
        return notificationBannerSnippet(value, maxLength: maxLength)
    }

    static nonisolated func isJSONBlobAssistantMessage(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return false
        }
        return true
    }
}

/// Redacts secrets, URL credentials, emails, and home paths from banner text
/// before it reaches OS notification surfaces. Pure and Sendable.
private nonisolated let notificationBannerScrubber = SentryScrubber()

private nonisolated func feedNotificationSourceDisplayName(_ source: String) -> String {
    RestorableAgentKind(rawValue: source)?.displayName
        ?? notificationBannerNonEmpty(source)?.capitalized
        ?? String(localized: "feed.notification.source.agent", defaultValue: "Agent")
}

private nonisolated func feedNotificationPermissionBody(toolName: String?, toolInputJSON: String?) -> String {
    let object = notificationBannerJSONObject(toolInputJSON)
    let tool = notificationBannerNonEmpty(toolName)
        ?? notificationBannerNonEmpty(object?["permission"] as? String)
        ?? notificationBannerNonEmpty(object?["tool_name"] as? String)
        ?? notificationBannerNonEmpty(object?["toolName"] as? String)

    let detail = notificationBannerNonEmpty(object?["command"] as? String)
        ?? notificationBannerFileBasename(object?["file_path"] as? String)
        ?? notificationBannerFileBasename(object?["filePath"] as? String)
        ?? notificationBannerFirstPattern(object?["patterns"])

    if let tool, let detail {
        return String.localizedStringWithFormat(
            String(localized: "feed.notification.permission.allowBody", defaultValue: "Allow %@: %@"),
            tool,
            NotificationBannerComposer.notificationBannerSnippet(detail, maxLength: 120) ?? detail
        )
    }

    if let tool {
        return String.localizedStringWithFormat(
            String(localized: "feed.notification.permission.body", defaultValue: "%@ needs approval"),
            tool
        )
    }

    return String(localized: "feed.notification.decisionNeeded", defaultValue: "Decision needed")
}

private nonisolated func feedNotificationQuestionBody(toolInputJSON: String?) -> String {
    if let object = notificationBannerJSONObject(toolInputJSON),
       let question = notificationBannerQuestion(from: object) {
        return question
    }

    return String(localized: "feed.notification.question.body", defaultValue: "Agent is asking a question")
}

private nonisolated func feedNotificationExitPlanBody(toolInputJSON: String?) -> String {
    guard let object = notificationBannerJSONObject(toolInputJSON) else {
        return String(localized: "feed.notification.exitPlan.body", defaultValue: "Review and approve the plan")
    }

    if let question = notificationBannerJSONObject(object["tool_input"]).flatMap({ notificationBannerNonEmpty($0["question"] as? String) })
        ?? notificationBannerNonEmpty(object["question"] as? String) {
        return NotificationBannerComposer.notificationBannerSnippet(question, maxLength: 120) ?? question
    }

    let plan = notificationBannerJSONObject(object["tool_input"]).flatMap({ notificationBannerNonEmpty($0["plan"] as? String) })
        ?? notificationBannerNonEmpty(object["plan"] as? String)
    if let line = plan?.components(separatedBy: .newlines).compactMap(notificationBannerNonEmpty).first {
        return NotificationBannerComposer.notificationBannerSnippet(line, maxLength: 120) ?? line
    }

    return String(localized: "feed.notification.exitPlan.body", defaultValue: "Review and approve the plan")
}

private nonisolated func notificationBannerQuestion(from object: [String: Any]) -> String? {
    if let questions = object["questions"] as? [[String: Any]],
       let first = questions.first,
       let question = notificationBannerNonEmpty(first["question"] as? String) {
        return NotificationBannerComposer.notificationBannerSnippet(question, maxLength: 120) ?? question
    }
    if let nested = notificationBannerJSONObject(object["tool_input"]),
       let question = notificationBannerQuestion(from: nested) {
        return question
    }
    return nil
}

private nonisolated func notificationBannerJSONObject(_ value: Any?) -> [String: Any]? {
    if let object = value as? [String: Any] {
        return object
    }
    guard let string = value as? String,
          let data = string.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
    else {
        return nil
    }
    return object
}

private nonisolated func notificationBannerFileBasename(_ value: String?) -> String? {
    guard let value = notificationBannerNonEmpty(value) else { return nil }
    let name = URL(fileURLWithPath: value).lastPathComponent
    return notificationBannerNonEmpty(name) ?? value
}

private nonisolated func notificationBannerFirstPattern(_ value: Any?) -> String? {
    if let patterns = value as? [String] {
        return patterns.compactMap(notificationBannerNonEmpty).first
    }
    if let patterns = value as? [Any] {
        return patterns.compactMap { notificationBannerNonEmpty($0 as? String) }.first
    }
    return nil
}

private nonisolated func notificationBannerNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
